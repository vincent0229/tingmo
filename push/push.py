#!/usr/bin/env python3
"""听墨推送层：纪要 JSON → 行动项结构化 → 钉钉/飞书双平台（只推本人）。

用法：
  python3 push/push.py --note /path/note.json [--dry-run]
note.json 为适配层/App 产出的五字段：title/summary/keywords/todos/chapters。

规则（routing.json v2）：
- 只推本人，绝不自动进群；群映射仅作「建议转发」提示
- 待办只建本人主导或配合项，配合项加 [配合] 前缀
- 写后回读验证
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import date, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(HERE, "config.json"), encoding="utf-8"))
ROUTING = json.load(open(os.path.join(HERE, CFG["routing_file"]), encoding="utf-8"))


def run(argv):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=180)
    out = p.stdout.strip()
    try:
        return json.loads(out)
    except Exception:
        return {"_raw": out, "_err": p.stderr.strip()[-500:], "_code": p.returncode}


def llm(messages):
    body = {"model": CFG["llm_model"], "response_format": {"type": "json_object"},
            "messages": messages}
    req = urllib.request.Request(CFG["ollama_url"] + "/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    res = json.load(urllib.request.urlopen(req, timeout=300))
    return json.loads(res["choices"][0]["message"]["content"])


def structure_actions(note):
    """todos 纯文本 → [{item, owner, role(主导/配合/其他), due(ISO)}]，只保留本人相关。"""
    me = CFG["user_name"]
    system = (
        f"你是会议纪要行动项解析器。当前用户：{me}。今天：{date.today().isoformat()}。"
        "把输入的行动项列表解析为 JSON：{\"actions\":[{\"item\":\"事项\",\"owner\":\"负责人姓名\","
        "\"role\":\"主导|配合|其他\",\"due\":\"YYYY-MM-DD或null\"}]}。"
        f"role 判断：{me}负责=主导；{me}协助他人=配合；他人负责且无需{me}=其他。"
        "文中没有明确负责人时 owner 填 null。只依据输入，不要编造。"
    )
    user = json.dumps({"todos": note.get("todos", []), "summary": note.get("summary", "")},
                      ensure_ascii=False)
    j = llm([{"role": "system", "content": system}, {"role": "user", "content": user}])
    mine = []
    for a in j.get("actions", []):
        if a.get("owner") == me and a.get("role") in ("主导", "配合"):
            prefix = "[配合] " if a["role"] == "配合" else ""
            due = a.get("due") or None
            mine.append({"title": prefix + a["item"], "due": due})
    return mine


def suggest_groups(note):
    text = (note.get("title", "") + " " + " ".join(note.get("keywords", []))).lower()
    hits = []
    for r in ROUTING.get("suggestions", {}).get("rules", []):
        if any(k.lower() in text for k in r.get("keywords", [])):
            hits += [f"{g}（{r['platform']}）" for g in r.get("groups", [])]
    return hits


def note_markdown(note, actions):
    lines = [f"# {note.get('title', '会议纪要')}", "",
             f"> 听墨本地转写 · {datetime.now().strftime('%Y-%m-%d %H:%M')} · 音频不出本机", "",
             "## 摘要", note.get("summary", ""), "",
             "## 关键词", "、".join(note.get("keywords", [])), "",
             "## 行动项（本人）"]
    if actions:
        lines += ["| 事项 | 截止 |", "|---|---|"]
        lines += [f"| {a['title']} | {a['due'] or '—'} |" for a in actions]
    else:
        lines.append("无")
    if note.get("chapters"):
        lines += ["", "## 章节"]
        lines += [f"- {c.get('title', '')}：{c.get('summary', '')}" for c in note["chapters"]]
    lines += ["", "## 待办原文"] + [f"- {t}" for t in note.get("todos", [])]
    return "\n".join(lines)


def push_dingtalk(md, note, actions, suggestion, dry):
    """DWS 宿主网关禁止脚本内调用 dws → 输出命令计划，由助手逐条直执。"""
    me = CFG["user_name"]
    title = note.get("title", "会议纪要")
    msg = f"【听墨】{title}\n全文：{{doc_url}}\n我的待办：{len(actions)} 条"
    if suggestion:
        msg += "\n建议转发：" + "、".join(suggestion)
    plan = [{"purpose": "建文档", "argv": ["dws", "doc", "+create", "--name", f"听墨·{title}",
                                          "--content", md, "--format", "json"]}]
    for a in actions:
        argv = ["dws", "todo", "+remind", "--task", a["title"], "--yes", "--format", "json"]
        if a["due"]:
            argv += ["--at", a["due"] + "T18:00:00+08:00"]
        plan.append({"purpose": "待办:" + a["title"], "argv": argv})
    plan.append({"purpose": "私信(把{doc_url}换成真实链接)", "argv":
                 ["dws", "chat", "+dm", "--to", me, "--content", msg, "--yes", "--format", "json"]})
    pf = os.path.join(HERE, "dingtalk-plan.json")
    json.dump(plan, open(pf, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    open(os.path.join(HERE, "last-note.md"), "w", encoding="utf-8").write(md)
    print(f"钉钉计划 {len(plan)} 条 → {pf}（由助手直执）")
    return {"platform": "dingtalk", "mode": "plan", "commands": len(plan)}


def push_feishu(md, note, actions, suggestion, dry):
    title = note.get("title", "会议纪要")
    if dry:
        print("[dry] 飞书：文档+任务x%d+消息" % len(actions))
        return {}
    body = md.split("\n", 1)[1] if md.startswith("# ") else md
    doc = run(["lark-cli", "docs", "+create", "--title", f"听墨·{title}", "--markdown", body])
    url = doc.get("data", {}).get("doc_url", "")
    doc_id = doc.get("data", {}).get("doc_id", "")
    if not url:
        print("飞书文档创建失败:", json.dumps(doc, ensure_ascii=False)[:300])
        return {}
    back = run(["lark-cli", "docs", "+fetch", "--doc", doc_id])
    ok = back.get("ok", False)
    for a in actions:
        argv = ["lark-cli", "task", "+create", "--summary", a["title"],
                "--assignee", CFG["feishu_open_id"]]
        if a["due"]:
            argv += ["--due", a["due"] + "T18:00:00+08:00"]
        t = run(argv)
        print("  任务:", a["title"], "→", t.get("data", {}).get("guid") or t)
    msg = f"【听墨】{title}\n全文：{url}\n我的待办：{len(actions)} 条"
    if suggestion:
        msg += "\n建议转发：" + "、".join(suggestion)
    m = run(["lark-cli", "im", "+messages-send", "--as", "bot",
             "--user-id", CFG["feishu_open_id"], "--text", msg])
    if not m.get("ok"):
        print("  消息首发失败:", json.dumps(m, ensure_ascii=False)[:200], "→ 重试")
        m = run(["lark-cli", "im", "+messages-send", "--as", "bot",
                 "--user-id", CFG["feishu_open_id"], "--text", msg])
    print("  消息:", m.get("ok"), m.get("data", {}).get("message_id", ""))
    return {"platform": "feishu", "doc_url": url, "readback": ok, "todos": len(actions)}


def parse_md(path):
    """解析 App 产出的 Markdown 纪要（标准/决策等模板）→ 五字段 note。"""
    text = open(path, encoding="utf-8").read()
    note = {"title": "", "summary": "", "keywords": [], "todos": [], "chapters": []}
    m = re.search(r"^#\s+(.+)$", text, re.M)
    if m:
        note["title"] = re.sub(r"^\d{6}\s*-\s*", "", m.group(1)).replace(" 会议纪要", "").strip()
    km = re.search(r"关键词[语]?[：:]\**\s*(.+)", text)
    if km:
        note["keywords"] = [k.strip() for k in re.split(r"[、,，]", km.group(1)) if k.strip() and k.strip() != "—"]

    def section(pat):
        sm = re.search(r"^##\s*[^\n]*" + pat + r"[^\n]*\n(.*?)(?=^##\s|\Z)", text, re.M | re.S)
        return sm.group(1).strip() if sm else ""

    note["summary"] = section(r"(摘要|结论)")
    todo_sec = section(r"待办")
    for line in todo_sec.splitlines():
        t = re.sub(r"^-\s*(\[[ x]\]\s*)?", "", line.strip()).strip()
        if t and "未识别" not in t and not t.startswith("|"):
            note["todos"].append(t)
    ch_sec = section(r"章节")
    for cm in re.finditer(r"###\s*`?[^`\n]*`?\s*(.+?)\n+(.*?)(?=###|\Z)", ch_sec, re.S):
        note["chapters"].append({"title": cm.group(1).strip(), "summary": cm.group(2).strip()})
    if not note["summary"] and not note["todos"]:
        j = llm([{"role": "system", "content":
                  "把输入的会议纪要文本解析为 JSON：{\"title\":\"\",\"summary\":\"\",\"keywords\":[],\"todos\":[],\"chapters\":[]}。只依据文本。"},
                 {"role": "user", "content": text[:12000]}])
        note.update({k: j.get(k, note[k]) for k in note})
    return note


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--note", required=True, help="纪要 JSON 或 App 产出的 Markdown")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.note.lower().endswith((".md", ".markdown")):
        note = parse_md(args.note)
    else:
        note = json.load(open(args.note, encoding="utf-8"))
    actions = structure_actions(note)
    suggestion = suggest_groups(note)
    md = note_markdown(note, actions)
    print(f"纪要：{note.get('title')} | 本人待办 {len(actions)} 条 | 建议转发：{suggestion or '无'}")
    results = []
    if CFG["dingtalk_enabled"]:
        results.append(push_dingtalk(md, note, actions, suggestion, args.dry_run))
    if CFG["feishu_enabled"]:
        results.append(push_feishu(md, note, actions, suggestion, args.dry_run))
    print(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()