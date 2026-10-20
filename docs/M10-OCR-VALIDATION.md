# Glint M10 OCR Validation

- 日期：2026-10-20
- 目标：在不替换苹果输入法的前提下，稳定读取当前高亮候选
- 结论：默认使用 Apple Vision，PP-OCRv6 small 作为按需安装插件

## 1. 选型结论

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| PP-OCRv6 small | 增强插件 | 体积和准确率均衡，原生推理稳定，模型约 20MB |
| PP-OCRv6 medium | 高质量插件 | 使用相同运行时和字符表，模型约 76.5MB，适合复杂候选 |
| PP-OCRv6 tiny | 不采用 | 速度更快但小字号和模糊背景误识别明显 |
| Apple Vision | 默认 | 无需模型分发，满足开箱即用；复杂背景时准确率低于 small |
| Tesseract 5 | 不采用 | 中文候选场景精度和鲁棒性不足 |
| GLM-OCR 0.9B / HunyuanOCR 1B | 不进入热路径 | 视觉语言模型适合文档理解，不适合每次按键触发的毫秒级字幕识别 |
| MinerU | 不采用 | 面向 PDF/文档版面还原，流水线过重 |

Glint 只需要识别已经定位好的候选胶囊，不运行完整的 OCR 文本检测流水线。

运行时顺序：

```text
蓝色胶囊定位
  → 裁切候选
  → 当前识别引擎
  → 无结果或低置信度
  → 另一识别引擎
  → 候选清洗
  → 词典/翻译路由
```

默认当前引擎为 Apple Vision；用户安装 PP-OCR 并点击“使用”后，优先使用
PP-OCR。两个引擎互为回退。

## 2. 基准结果

测试机器：Apple M4 Pro、48GB、macOS 26.5。数据集包含 1 张真实候选截图、4 张真实截图变体和 400 张受控合成候选。

| 引擎 | 精确匹配 | 字符错误率 | p50 | p95 |
| --- | ---: | ---: | ---: | ---: |
| Apple Vision | 93.58% | 4.94% | 16.01ms | 20.05ms |
| PP-OCRv6 tiny | 90.86% | 4.81% | 1.31ms | 1.74ms |
| **PP-OCRv6 small** | **99.51%** | **0.25%** | **3.97ms** | **4.45ms** |

Swift/ONNX Runtime 原生基准在 405 个样本上达到 99.75% 精确匹配；完整 OCR 链路 p50 约 10–18ms，p95 约 12–22ms。唯一失败样本为 `显示 → 示`。

合成样本用于比较模型和延迟，不代表生产环境的真实准确率。发布前仍需补充 100–200 张来自不同 App、主题、字号和显示器缩放的真实截图。

完整报告：`Tools/OCRLab/results/report.md`

## 3. 原生实现

- ONNX Runtime 通过 C ABI 桥接，并随主 App 一起签名分发；
- PP-OCR 使用 recognition-only 模型，输入宽度按候选宽高比动态计算；
- 同时测试图片上下两种预处理方向，再按文字完整度和置信度选择结果；
- PP-OCR 插件只下载约 20MB 的官方 `inference.onnx`，字符表随适配器内置；
- 模型固定到 Paddle 官方 Hugging Face revision，并校验官方 SHA-256；
- 下载顺序为 `GLINT_HF_ENDPOINT`、`hf-mirror.com`、`huggingface.co`；
- 使用中的插件被卸载后自动切回 Apple Vision；
- `GLINT_OCR_BACKEND=ppocr|vision|auto` 可切换后端；
- `GLINT_OCR_TRACE=1` 可输出裁剪尺寸、方向判定和置信度。

分发体积：

| 资源 | 大小 |
| --- | ---: |
| 主 App 内置 ONNX Runtime | 约 32MB |
| PP-OCRv6 small 模型下载 | 约 20MB |
| PP-OCRv6 medium 模型下载 | 约 76.5MB |

## 4. 已验证

- Xcode 测试和全部 Swift Package 测试通过；
- Release arm64 App 构建成功；
- 主 App 包含签名运行时和字符表，不包含 OCR 模型权重；
- PP-OCR 模型经国内镜像成功下载并校验官方 SHA-256 后安装；
- PP-OCRv6 medium 下载和真实候选识别通过；
- 自检分别在 Apple Vision 优先和 PP-OCR 优先模式下识别出 `你好`；
- TextEdit + 苹果拼音真实输入 `nihao`；
- OCR 识别焦点候选 `你好`；
- HUD 在候选栏下方显示 `Hello`。

## 5. 发行前待办

- 正式发行包需要将 `libonnxruntime.1.dylib` 作为嵌套代码与 App 一起签名和公证；
- 扩大真实屏幕截图回归集，覆盖 TextEdit、浏览器、Office 和聊天工具；
- 增加非蓝色系统强调色下的候选定位；
- Debug 构建的 OCR 延迟明显高于 Release，性能结论应以 Release 为准。
