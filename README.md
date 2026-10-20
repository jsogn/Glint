# Glint

**在你的输入旁，看到英文。**

Glint 是一款面向中文母语者的 macOS 菜单栏工具。它读取苹果拼音候选栏中的焦点候选，
在候选栏上方或下方显示一行英文，让日常打字自然成为英语学习的一部分。

Glint 不替换苹果输入法，不抢焦点，也不读取输入框正文。

## 功能

- 自动定位苹果拼音的焦点候选，并识别单词、短语或短句
- 单词和短语显示英文对应词，短句显示自然英文翻译
- 默认使用 Apple Vision，可安装 PP-OCRv6 Small / Medium 增强识别
- 翻译支持词典优先和模型优先，失败时自动回退另一来源
- 界面、候选间距、透明度、显示位置和显示延迟可调
- 支持离线词典、本地 MLX 模型和多个 OpenAI 兼容接口
- 模型按需下载，优先使用国内 Hugging Face 镜像

## 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac
- 开发需要 Xcode 26、Swift 6 和 XcodeGen

## 开发

```bash
# 生成 Xcode 工程
xcodegen generate

# 构建
./scripts/build.sh

# 构建并启动 App
./scripts/run.sh

# App 与全部 Package 测试
./scripts/test.sh

# 安装开发插件和本地插件目录
./scripts/install_dev_plugins.sh
```

`project.yml` 是 Xcode 工程配置的唯一来源。本地开发模型资源位于
`Resources/Models`、`Resources/CT2` 和 `Tools/ModelLab`，不会提交到仓库。

## OCR

默认识别引擎是 Apple Vision。用户可以在“插件与模型 → 文字识别”中安装：

- PP-OCRv6 Small：约 20MB，速度快、准确率均衡
- PP-OCRv6 Medium：约 76.6MB，更适合复杂候选

PP-OCR 权重固定到 Paddle 官方 Hugging Face revision，并校验 SHA-256。
下载依次尝试自定义端点、`hf-mirror.com` 和 `huggingface.co`。

## 翻译模型

- **本地 MLX**：支持导入包含权重、tokenizer、配置和聊天模板的 MLX 模型目录
- **OpenAI 兼容接口**：支持多个具名接口，可连接 Ollama、LM Studio 或远程服务
- **离线词典**：CC-CEDICT、ECDICT 和 Wiktionary 作为可管理插件

API Key 保存在 macOS 钥匙串，不写入明文配置。

## 隐私

Glint 不保存候选文本、翻译结果或输入历史。默认路径使用本地词典、本地 OCR
和本地翻译模型；如果用户主动启用 OpenAI 兼容接口，当前候选文本会发送到该接口。

## 第三方组件

- CC-CEDICT · CC BY-SA 4.0
- ECDICT · MIT
- Wiktionary data · CC BY-SA / GFDL
- PaddleOCR PP-OCRv6 · Apache-2.0
- ONNX Runtime · MIT
- MLX · MIT

各插件的许可证随插件目录一并提供。

## 文档

- [产品需求](docs/PRD-v0.3.md)
- [技术架构](docs/ARCHITECTURE-v0.1.md)
- [OCR 验证](docs/M10-OCR-VALIDATION.md)
- [插件目录与安装](docs/M7-PLUGIN-CATALOG.md)
