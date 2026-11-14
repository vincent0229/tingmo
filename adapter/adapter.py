#!/usr/bin/env python3
"""E1 本地转写适配层：把 E1Recorder CustomClient 契约分流到 whisper.cpp + ollama。

E1Recorder 里「自定义平台」填：
  API base = http://127.0.0.1:8090/v1   API key = 任意非空串
  ASR 模型 = whisper-small              LLM 模型 = qwen2.5:7b-instruct-q4_K_M

启动：./run.sh   （依赖：fastapi uvicorn python-multipart，whisper-cli，ollama 在跑）
"""
import json
import os
import subprocess
import tempfile
import urllib.request

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse

HERE = os.path.dirname(os.path.abspath(__file__))
WHISPER_CLI = os.environ.get("WHISPER_CLI", "/opt/homebrew/bin/whisper-cli")
MODEL = os.environ.get("WHISPER_MODEL", os.path.join(HERE, "models", "ggml-small.bin"))
OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
WHISPER_SERVER = os.environ.get("WHISPER_SERVER", "http://127.0.0.1:8081")
LANG = os.environ.get("WHISPER_LANG", "zh")
THREADS = os.environ.get("WHISPER_THREADS", "4")

app = FastAPI(title="E1 Local Adapter")


def _models():
    data = [{"id": "whisper-small", "object": "model", "owned_by": "local"}]
    try:
        with urllib.request.urlopen(OLLAMA + "/v1/models", timeout=5) as r:
            data += json.load(r).get("data", [])
    except Exception:
        pass
    return {"object": "list", "data": data}


def _map_segments(raw):
    """兼容 whisper-server（OpenAI 风格 segments）与 whisper-cli（transcription+offsets）两种输出。"""
    segments, texts = [], []
    if isinstance(raw.get("segments"), list):
        for s in raw["segments"]:
            text = (s.get("text") or "").strip()
            segments.append({"start": float(s.get("start", 0)), "end": float(s.get("end", 0)), "text": text})
            texts.append(text)
    else:
        for t in raw.get("transcription", []):
            off = t.get("offsets", {})
            text = (t.get("text") or "").strip()
            segments.append({"start": off.get("from", 0) / 1000.0, "end": off.get("to", 0) / 1000.0, "text": text})
            texts.append(text)
    return " ".join(texts).strip(), segments


def _transcribe_server(file_bytes: bytes, filename: str, response_format: str, prompt: str):
    boundary = "----e1adapter" + os.urandom(8).hex()
    parts = []
    fields = [("response_format", "verbose_json"), ("temperature", "0")]
    if prompt:
        fields.append(("prompt", prompt))
    for k, v in fields:
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename or 'audio.wav'}\"\r\nContent-Type: application/octet-stream\r\n\r\n".encode())
    parts.append(file_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    req = urllib.request.Request(WHISPER_SERVER + "/inference", data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=3600) as r:
        raw = json.load(r)
    text, segments = _map_segments(raw)
    if response_format == "json":
        return {"text": text}
    return {"text": text, "language": raw.get("language", LANG), "segments": segments}


def _transcribe_sync(file_bytes: bytes, filename: str, response_format: str, prompt: str):
    try:
        return _transcribe_server(file_bytes, filename, response_format, prompt)
    except Exception:
        pass  # 常驻服务不可用时回退 CLI（冷加载）
    suffix = os.path.splitext(filename or "audio.wav")[1] or ".wav"
    with tempfile.TemporaryDirectory(prefix="e1asr-") as td:
        path = os.path.join(td, "audio" + suffix)
        with open(path, "wb") as f:
            f.write(file_bytes)
        out_base = os.path.join(td, "out")
        cmd = [WHISPER_CLI, "-m", MODEL, "-f", path, "-l", LANG,
               "-t", THREADS, "-oj", "-of", out_base]
        if prompt:
            cmd += ["--prompt", prompt]
        proc = subprocess.run(cmd, capture_output=True, timeout=3600)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode(errors="replace")[-2000:])
        with open(out_base + ".json", encoding="utf-8") as f:
            raw = json.load(f)
    segments, texts = [], []
    for t in raw.get("transcription", []):
        off = t.get("offsets", {})
        text = t.get("text", "").strip()
        segments.append({"start": off.get("from", 0) / 1000.0,
                         "end": off.get("to", 0) / 1000.0, "text": text})
        texts.append(text)
    text = " ".join(texts).strip()
    if response_format == "json":
        return {"text": text}
    return {"text": text, "language": LANG, "segments": segments}


async def _chat(request: Request):
    body = await request.body()
    # 注入当前日期（App 的 prompt 不含日期，模型会把截止年份猜错）
    try:
        from datetime import date
        payload = json.loads(body)
        for m in payload.get("messages", []):
            if m.get("role") == "system":
                m["content"] += (f"\n当前日期：{date.today().isoformat()}，待办截止年份以此为准。"
                                 "\nsummary 字段务必写满 200 到 400 字，按议题逐一展开，不要过度精简；"
                                 "若转写内容本身不足，按实际内容输出，不要编造填充。"
                                 "\ntodos 字段必须是字符串数组。")
                break
        body = json.dumps(payload).encode()
    except Exception:
        pass
    req = urllib.request.Request(
        OLLAMA + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=600) as r:
        res = json.load(r)
    # 归一化 todos：qwen 可能输出对象数组，而 App 只接受字符串数组（as? [String]）
    try:
        content = res["choices"][0]["message"]["content"]
        j = json.loads(content)
        todos = j.get("todos")
        if isinstance(todos, list) and todos and isinstance(todos[0], dict):
            flat = []
            for t in todos:
                s = (t.get("title") or t.get("text") or t.get("任务")
                     or t.get("事项") or str(t))
                who = t.get("responsible") or t.get("负责人")
                due = t.get("due_date") or t.get("截止日期") or t.get("截止时间")
                if who:
                    s += f"（负责人：{who}"
                    if due:
                        s += f"，截止：{due}"
                    s += "）"
                elif due:
                    s += f"（截止：{due}）"
                flat.append(s)
            j["todos"] = flat
            res["choices"][0]["message"]["content"] = json.dumps(j, ensure_ascii=False)
    except Exception:
        pass
    return JSONResponse(res)


@app.get("/v1/models")
@app.get("/models")
def models():
    return _models()


@app.post("/v1/audio/transcriptions")
@app.post("/audio/transcriptions")
async def transcribe(file: UploadFile = File(...), model: str = Form("whisper-small"),
                     response_format: str = Form("verbose_json"), prompt: str = Form("")):
    # 日历热词注入（FR-14）：push/hotwords.py 生成的今日参会人/项目名
    hw_file = os.path.join(HERE, "hotwords.txt")
    if os.path.exists(hw_file):
        hw = "、".join(l.strip() for l in open(hw_file, encoding="utf-8") if l.strip())
        if hw:
            prompt = (prompt + " 专有名词：" + hw).strip()
    try:
        data = _transcribe_sync(await file.read(), file.filename or "", response_format, prompt)
        return JSONResponse(data)
    except Exception as e:
        return JSONResponse({"error": {"message": str(e)}}, status_code=500)


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def chat(request: Request):
    try:
        return await _chat(request)
    except Exception as e:
        return JSONResponse({"error": {"message": str(e)}}, status_code=502)


@app.get("/health")
def health():
    return {"ok": True, "model": MODEL,
            "model_exists": os.path.exists(MODEL), "ollama": OLLAMA}