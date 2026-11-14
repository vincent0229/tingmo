#!/bin/bash
# 听墨一键安装（macOS 15+ / Apple Silicon）
# 用法：./install.sh   （幂等，可重复跑）
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

echo "== 1/5 依赖 =="
command -v brew >/dev/null || { echo "请先安装 Homebrew: https://brew.sh"; exit 1; }
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
brew list android-platform-tools >/dev/null 2>&1 || brew install android-platform-tools
python3 -c "import fastapi, uvicorn" 2>/dev/null || pip3 install --user fastapi uvicorn python-multipart
if ! command -v ollama >/dev/null; then
  echo "!! 未检测到 ollama，请安装后重跑: https://ollama.com"
else
  ollama list | grep -q "qwen2.5:7b-instruct-q4_K_M" || ollama pull qwen2.5:7b-instruct-q4_K_M
fi

echo "== 2/5 模型（ModelScope，约547MB）=="
mkdir -p models
if [ ! -f models/ggml-large-v3-turbo-q5_0.bin ]; then
  curl -L --retry 3 -o models/ggml-large-v3-turbo-q5_0.bin \
    "https://modelscope.cn/models/iceCream2025/whisper.cpp/resolve/master/ggml-large-v3-turbo-q5_0.bin"
fi

echo "== 3/5 常驻服务（launchd）=="
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$HOME/Library/LaunchAgents/com.tingmo.whisper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tingmo.whisper</string>
  <key>ProgramArguments</key><array>
    <string>/opt/homebrew/bin/whisper-server</string>
    <string>-m</string><string>$ROOT/models/ggml-large-v3-turbo-q5_0.bin</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>8081</string>
    <string>-l</string><string>zh</string>
    <string>-t</string><string>4</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/tingmo-whisper.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/tingmo-whisper.log</string>
</dict></plist>
PLIST
cat > "$HOME/Library/LaunchAgents/com.tingmo.adapter.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tingmo.adapter</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$ROOT/adapter/run.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT/adapter</string>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/tingmo-adapter.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/tingmo-adapter.log</string>
</dict></plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.tingmo.whisper.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.tingmo.adapter.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.tingmo.whisper.plist"
launchctl load "$HOME/Library/LaunchAgents/com.tingmo.adapter.plist"

echo "== 4/5 验证 =="
sleep 8
curl -s --retry 10 --retry-connrefused --retry-delay 2 http://127.0.0.1:8081/health && echo " <- whisper-server"
curl -s --retry 10 --retry-connrefused --retry-delay 2 http://127.0.0.1:8090/health && echo " <- adapter"

echo "== 5/5 完成 =="
cat <<'TXT'
App 配置（E1录音助手/听墨 → 设置 → 服务平台 → 自定义）：
  接口地址  http://127.0.0.1:8090/v1
  访问密钥  任意非空串
  识别模型  whisper-small
  整理模型  qwen2.5:7b-instruct-q4_K_M
推送层：编辑 push/config.json 后运行 python3 push/push.py --note <纪要.md|json>
卸载：launchctl unload ~/Library/LaunchAgents/com.tingmo.{whisper,adapter}.plist
TXT