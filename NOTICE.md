# 第三方组件与许可声明

本项目基于以下开源组件构建，按各自许可证要求保留声明：

## E1Recorder（MIT）
- 项目：https://github.com/seabird000/E1Recorder
- 版权：Copyright (c) 2026 seabird000
- 用途：笔端同步脚本（pen/）与 Mac App 源码参考/派生。派生版本须随附原 MIT 许可证全文与版权声明（见 upstream/LICENSE-E1Recorder）。
- 要求：在 App「关于」页与分发物中保留原作者署名；不得用原作者名义为派生产品背书。

## Android platform-tools / adb（Apache-2.0）
- 版权：The Android Open Source Project
- 用途：App 内捆绑的 adb 二进制，用于 USB 同步。
- 要求：随附 NOTICE 与 Apache-2.0 许可证文本（App  Resources/adb-NOTICE.txt 已含）。

## whisper.cpp（MIT）
- 项目：https://github.com/ggml-org/whisper.cpp
- 用途：本地语音转写引擎。模型权重（ggml）来自 OpenAI Whisper（MIT）。

## ollama（MIT）+ Qwen2.5（Apache-2.0）
- 用途：本地纪要整理 LLM 运行时与模型。

## 搜狗 E1 固件
- 本仓库**不包含**任何搜狗固件、镜像或专有代码。
- 设备分区备份（dd 产物）仅供本机恢复使用，**禁止入库或分发**。