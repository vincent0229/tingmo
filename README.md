# 听墨 · E1 私有化录音转写工作站

声音落成墨迹。搜狗 E1 录音笔 + Mac 本地转写 + 钉钉/飞书双平台分发的私有化会议记录方案。
音频不出本机，运行成本 ¥0。基于 [E1Recorder](https://github.com/seabird000/E1Recorder)（MIT）二次开发。

- `app/`：听墨 App 源码（E1Recorder MIT 派生，subtree 并入，含上游历史；上游更新用 `git subtree pull --prefix=app upstream main`）

## 路线图

[docs/ROADMAP.md](docs/ROADMAP.md)（含功能全景图）

## 结构

| 目录/文件 | 说明 |
|---|---|
| `adapter/` | 本地转写适配层（FastAPI，8090 端口）：/audio/transcriptions → whisper.cpp，/chat/completions → ollama |
| `routing.json` | 分发规则：只推本人 + 建议转发提示 + 待办主导/配合规则 |
| `PRD.md` | 产品需求文档（FR-01~15 + 里程碑 + 探针清单） |
| `方案设计与功能扩展.md` | 六层架构设计 + 社区玩法评估 |
| `E1功能全景研究.md` | 硬件能力底牌 + 8 类 28 项功能全景 |
| `models/` | 本地模型（git 忽略，从 ModelScope 下载） |
| `app/` | 听墨 App 源码（Swift/SwiftPM，构建见 app/build.sh） |
| `E1Recorder/` | 上游参考克隆（git 忽略） |

## 快速开始

```bash
# 1. 适配层（依赖：whisper.cpp、ollama、fastapi）
adapter/run.sh

# 2. E1录音助手 App → 设置 → 服务平台 → 自定义
#    接口地址 http://127.0.0.1:8090/v1
#    识别模型 whisper-small（实际用 models/ 下的 turbo）
#    整理模型 qwen2.5:7b-instruct-q4_K_M
```

## 许可

MIT（见 LICENSE）。第三方组件声明见 NOTICE.md。