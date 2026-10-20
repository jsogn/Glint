# Glint M4 Validation

- 日期：2026-10-20
- 机器：MacBook Pro，Apple M4 Pro，48GB，macOS 26.6.2
- 构建：Debug / Apple Silicon
- 输入源：苹果拼音 `com.apple.inputmethod.SCIM.ITABC`
- 测试词：`nihao`、`suanfa`

## 1. 兼容性结果

| App | 测试位置 | 结果 | 证据 |
|---|---|---|---|
| TextEdit | 新建文档正文 | 通过 | `落 → leave out`、`逻辑 → logic (loanword)`、`进行 → advance` |
| Safari | 页面普通 `<textarea>` | 通过 | 候选“算法”显示 `algorithm` |
| Chrome | 页面普通 `<textarea>` | 通过 | 日志 `算法 → algorithm` |
| VS Code | 命令面板输入框 | 通过 | 候选“算法”显示 `algorithm` |
| 微信 | 左上角搜索框 | 通过 | 修复误判后日志 `算法 → algorithm` |
| Safari 密码框 | `type=password` | 通过 | 日志 `安全输入场景已跳过` |
| Microsoft Word | — | 未测试 | 当前机器未安装 Microsoft Word |

当前验证机只有一个显示器，因此多显示器场景尚未覆盖。

## 2. 本次发现并修复的问题

### 候选高亮被更大的蓝色 UI 误判

微信搜索框的候选中高亮“算法”可见，但 Glint 返回：

```text
未检测到高亮候选
```

原因：

- 原算法选择截取区域中面积最大的蓝色组件；
- 微信当前页面中的装饰图/浮层也包含较大的蓝色区域；
- 装饰区域被当作候选高亮，后续 OCR 无法得到有效候选文本。

修复：

- 限制候选高亮的最大宽、高和面积，排除大面积装饰色块；
- 将光标中心映射到截图像素坐标；
- 在多个候选蓝色组件中选择距离光标最近的组件，不再单纯选择面积最大者。

代码：

- `Packages/GlintMac/Sources/GlintMac/OCR/OCRService.swift`
- `Packages/GlintMac/Sources/GlintMac/MonitoringController.swift`

### 自身窗口被 OCR 误判

测试时 Glint 主窗口自身的蓝色按钮可能被截入并识别为候选。

修复：ScreenCaptureKit 排除 Glint 自身进程窗口。

## 3. 环境注意事项

`Input Source Pro` 会按 App 自动切换输入源。测试期间它为部分 App 选择了 ABC，导致拼音候选栏不出现；临时退出后矩阵测试正常，测试完成后已重新启动。

这不是 Glint 的输入源判断错误。若用户遇到一直显示“等待苹果拼音”，应检查当前 App 的实际输入源，以及 Input Source Pro 等自动切换工具的规则。

## 4. 下一步

1. 补齐 Word 和多显示器验收；
2. 修正主窗口中仍为静态或空动作的 UI 状态；
3. 实现真实插件状态、HUD 预览和远程插件下载。
