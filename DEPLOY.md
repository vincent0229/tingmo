# 听墨本地转写服务部署手册

适用：macOS 15+ / Apple Silicon。全链路本地，运行成本 ¥0。

## 架构

```
E1 录音笔 ──USB──▶ E1录音助手/听墨 App ──HTTP──▶ 适配层 :8090
                                                  ├─ /audio/transcriptions → whisper.cpp
                                                  └─ /chat/completions → ollama :11434
App 产出纪要 ──▶ push/push.py ──▶ 钉钉(命令计划+助手直执) / 飞书(全自动)
```

## 0. 一键安装（推荐）

```bash
./install.sh    # 依赖+模型+launchd 常驻+验证，幂等可重复跑
```

以下手动步骤供排查/定制参考。

## 1. 依赖安装

```bash
brew install whisper-cpp android-platform-tools   # 转写引擎 + adb
pip3 install --user fastapi uvicorn python-multipart
# ollama 另行安装（https://ollama.com），并拉取摘要模型：
ollama pull qwen2.5:7b-instruct-q4_K_M
```

## 2. 模型下载（ModelScope，国内快；hf-mirror 易卡死）

```bash
mkdir -p models && cd models
# 冒烟用（181MB）
curl -L -o ggml-small-q5_1.bin \
  https://modelscope.cn/models/iceCream2025/whisper.cpp/resolve/master/ggml-small-q5_1.bin
# 正式用（547MB，中文更好、更快）
curl -L -o ggml-large-v3-turbo-q5_0.bin \
  https://modelscope.cn/models/iceCream2025/whisper.cpp/resolve/master/ggml-large-v3-turbo-q5_0.bin
```

`adapter/run.sh` 默认用 turbo；换模型改 `WHISPER_MODEL` 环境变量。

## 3. 启动适配层

转写默认走常驻 whisper-server（:8081，launchd 托管，模型驻留内存，48s 音频约 4s 出稿）；
服务不可用时适配层自动回退 whisper-cli 冷加载（约 16s）。

手动：

```bash
adapter/run.sh          # 前台，127.0.0.1:8090
```

开机自启（launchd，崩溃自动重拉）：

```bash
cp deploy/com.tingmo.adapter.plist ~/Library/LaunchAgents/
# 注意：plist 内路径按实际工作目录修改
launchctl load ~/Library/LaunchAgents/com.tingmo.adapter.plist
```

日志：`~/Library/Logs/tingmo-adapter.log`

## 4. App 接入

E1录音助手（或听墨）→ 设置 → 服务平台 → **自定义…**：

| 字段 | 值 |
|---|---|
| 接口地址 | `http://127.0.0.1:8090/v1` |
| 访问密钥 | 任意非空串（如 `local-e1`，仅存本机钥匙串） |
| 识别模型 | `whisper-small`（名称任意，实际用 run.sh 配置的模型） |
| 整理模型 | `qwen2.5:7b-instruct-q4_K_M`（须与 ollama 模型 ID 完全一致） |

点「连接测试」应通过。同步用 USB 模式（WiFi 同步需 OSS，免费方案不走）。

## 5. 推送层（可选）

```bash
# 配置 push/config.json：user_name / feishu_open_id / 平台开关
python3 push/push.py --note <纪要.json> --dry-run   # 预览
python3 push/push.py --note <纪要.json>             # 飞书自动；钉钉生成 push/dingtalk-plan.json
```

钉钉腿由助手在宿主侧直执计划中的 dws 命令（DWS 网关禁止脚本内调用）。
日历热词：助手直执 `dws calendar +agenda --format json --output /tmp/dws-agenda.json` 后跑 `python3 push/hotwords.py`，适配层转写时自动合并 `adapter/hotwords.txt`。

## 6. 验证清单

```bash
curl -s http://127.0.0.1:8090/health                 # model_exists=true
curl -s http://127.0.0.1:8090/v1/models              # 含 whisper + ollama 模型
# 转写（任意 16k wav）
curl -s -X POST http://127.0.0.1:8090/v1/audio/transcriptions \
  -F "file=@test.wav" -F "response_format=verbose_json"
# 无真实录音时可用 macOS TTS 造样本：
say -v Tingting -o t.aiff "测试会议内容" && ffmpeg -i t.aiff -ar 16000 -ac 1 test.wav
```

## 7. 故障排查

| 症状 | 原因/处理 |
|---|---|
| 连接测试失败 | 适配层没起：`curl /health`；端口占用 `lsof -i:8090` |
| 转写 500 | 模型路径错/文件不全：看 health 的 model_exists；日志 tingmo-adapter.log |
| 纪要为空/报错 | ollama 没起或模型 ID 不符：`ollama list` 核对 |
| 待办在 App 里丢失 | 模型输出对象数组——适配层已归一化，确认用的是本仓 adapter |
| 年份错误 | 适配层已注入当前日期，确认 adapter 版本 |
| 钉钉脚本调用被拒 | DWS 宿主网关限制，走命令计划+助手直执 |
| 飞书消息显示应用名 | CLI 仅支持 bot 身份发消息，属预期 |

## 8. 卸载

```bash
launchctl unload ~/Library/LaunchAgents/com.tingmo.adapter.plist
# 删除 ~/Library/LaunchAgents/com.tingmo.adapter.plist 与 models/ 即可，无系统级残留
```