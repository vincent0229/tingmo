#!/bin/bash
# E1 本地转写适配层启动脚本
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
export WHISPER_MODEL="${WHISPER_MODEL:-$(pwd)/../models/ggml-large-v3-turbo-q5_0.bin}"
PY=/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
exec "$PY" -m uvicorn adapter:app --host 127.0.0.1 --port 8090