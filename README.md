# Glint

面向中文母语者的 macOS 英文学习工具。输入中文时，Glint 会在拼音候选栏旁显示
对应的英文，让查词和英语接触自然融入日常输入。

![在日常中文输入中学习英文](docs/assets/glint-usage.png)

Glint 不替换输入法，不抢焦点，也不改变候选顺序。它只读取当前拼音候选，
并在你写作、聊天或搜索时提供即时、单行的英文参考。

## 功能

- 优先支持苹果拼音 `Pinyin - Simplified`；其他暴露 AX 候选的拼音输入法会尽量识别
- 选中模式跟随当前焦点候选；一栏模式按输入法序号显示整栏候选的英文
- 支持单词、短语和短句；单词提供常用英文对应词，短句提供自然翻译
- 可选词典优先或模型优先，未命中或失败时自动回退另一来源
- 内置 CC-CEDICT、ECDICT、Wiktionary 和轻量 OPUS-MT 翻译模型
- 支持下载更大离线翻译模型、导入本地 MLX 模型，以及配置多个 OpenAI 兼容接口
- 可调整 HUD 位置、候选停留时间、背景材质、颜色、透明度、字号、留白和间距
- 通过主窗口管理翻译模式、显示效果、插件与模型、权限和隐私设置

第三方输入法是否可用取决于它是否向 macOS 辅助功能暴露候选文本、当前选中项和位置；
无法读取时会静默跳过，不影响苹果拼音主路径。

## 从源码运行

需要 macOS 26 或更高版本、Apple Silicon Mac、Xcode 26 和 XcodeGen：

```bash
git clone https://github.com/jsogn/Glint.git
cd Glint
./scripts/run.sh
```

首次构建会把固定 revision 的 OPUS-MT 转换为 CTranslate2 int8，校验产物后
打入 `Glint.app`。转换工具和源文件会缓存在 Git 忽略目录中；之后构建可复用。
源模型默认从 `hf-mirror.com` 下载，也可以通过 `GLINT_HF_ENDPOINT` 指定镜像。
最终 App 启动和翻译均使用内置本地资源，不需要联网。

如需在不具备 Developer ID 的情况下制作内部测试 DMG：

```bash
./scripts/package_test_dmg.sh
```

产物位于 `build-release/`，使用 ad-hoc 签名，因此仍需在目标 Mac 上通过
“隐私与安全性”手动允许首次打开。

## 开始使用

1. 打开 Glint。
2. 按提示授权辅助功能。
3. 切换到苹果拼音 `Pinyin - Simplified` 并正常输入，候选栏旁会显示对应英文。

首次使用时，可在主窗口中配置翻译来源和显示效果。单词、短语和短句均可直接
使用内置能力；如需更高质量，可安装更大的离线模型或启用 OpenAI 兼容接口。

## 故障诊断

如果授权后没有显示英文，可运行：

```bash
/Applications/Glint.app/Contents/MacOS/Glint --diagnose
```

诊断输出不包含候选原文，只报告权限、输入源、前台 App、光标和候选发现状态。

## 隐私

- Glint 不保存候选文本、翻译结果或输入历史。
- 不截图、不执行 OCR，也不安装键盘事件监听。
- 只读取输入法候选和显示位置，不读取输入框正文或选中文字内容。
- 密码框、终端安全输入等场景自动跳过。
- 词典查询和本地模型推理均在本机完成，不联网。
- 只有主动启用 OpenAI 兼容接口时，当前候选文本才会发送到所配置的服务；
  API Key 保存在系统钥匙串中。
