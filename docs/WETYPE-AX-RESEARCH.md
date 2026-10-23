# 微信输入法 AX 接入调研

- 分支：`codex/wechat-input-ax-research`
- 日期：2026-10-23
- 系统：macOS 26.6.2（25G83）
- 微信输入法：3.0.0（Build 670）
- 输入源：`com.tencent.inputmethod.wetype.pinyin`
- 探针：`Tools/GlintEval/Sources/WeTypeAXProbe`

## 结论

微信输入法会把候选栏作为独立 AX 窗口暴露，没有
`InputMethodCandidateList`、`AXSelectedChildren` 或候选节点
`AXSelected`。但候选项的 `AXAttributedStringForRange` 会返回前景样式：

- 当前高亮项的数字和候选文字均变为纯白，亮度约 `1.0`；
- 未选中项的数字亮度约 `0.54`，候选文字约 `0.78`；
- 方向键切换后，唯一亮色数字组同步移动到新的候选。

因此不需要截图或屏幕录制权限。已新增 `WeTypeCandidateReader`，以唯一高亮
数字组确定当前候选；样式不可读或最大亮度不唯一时退回首候选。

微信静态文本的 frame 不包含绿色胶囊左侧的内边距。候选几何层按节点类型处理
这个差异：`text` 节点根据行高补足左侧视觉边界，`item`、`list` 和 `window`
节点保持原始 frame。当前 `28pt` 文字高度对应 `5pt` 左扩，右边缘不变；候选
识别仍使用原始文字 frame，避免影响样式、分组和方向键判断。微信纵向也使用
`text` 节点，因此不应用 `window` 节点针对搜狗默认皮肤的上下内缩。

## 实验方法

1. 仅在 TextEdit 新建的隔离空白文稿中输入固定测试拼音，未使用用户正文。
2. 在组合状态下检查宿主 App 和 `WeType` 进程的 AX 树。
3. 探针只记录角色、属性名、文本长度、frame 和选中/焦点状态，不输出候选原文。
4. 第一次采样后发送右方向键，比较候选节点和 attributed string 样式。
5. 结束后取消组合，恢复原输入源和前台 App，关闭并隔离测试文稿。

复现命令：

```bash
swift build --package-path Tools/GlintEval --product WeTypeAXProbe
Tools/GlintEval/.build/debug/WeTypeAXProbe --seconds 20
```

## 实测结构

组合输入时，宿主 TextEdit 没有候选列表。`WeType` 进程出现一个独立候选窗口：

- `AXRole = AXWindow`
- `AXSubrole = AXSystemDialog`
- frame：`x=200, y=214, width=510, height=32`
- 20 个直接子节点：18 个 `AXStaticText`、1 个 `AXButton`、1 个 `AXImage`
- 没有 `InputMethodCandidateList`
- 没有 `AXList`
- 没有非空 `AXSelectedChildren`
- `AXSections` 只有一个没有角色和属性的空元素
- 根窗口的 `AXChildrenInNavigationOrder` 有 20 个子节点，未暴露高亮索引
- 根窗口没有可用的 `AXTitleUIElement`

18 个静态文本节点都提供 `AXValue`、frame 和完整的
`AXVisibleCharacterRange`，因此候选文字和位置在 AX 中确实可读。但所有节点：

- `AXFocused = false`
- `AXSelectedTextRange.location = 0`
- `AXSelectedTextRange.length = 0`
- `AXSelectedText` 没有可读取的字符串值
- 不提供 `AXSelected`
- 不提供 `AXPress` 或其他候选选择 action

原生选中属性没有变化，但 `AXAttributedStringForRange` 的前景样式会变化。
实测三段状态：

```text
before  0:1.000 1:1.000 2:0.541 3:0.781 ...
right   0:0.541 1:0.781 2:1.000 3:1.000 ...
left    0:1.000 1:1.000 2:0.541 3:0.781 ...
```

每组前一个节点是候选序号，后一个节点是候选文字。唯一亮度显著更高的序号组
就是当前高亮候选。该样式只来自候选 AX 子树，不读取输入框正文。

## 可扩展边界

已经实现的部分：

- 通过 bundle ID `com.tencent.inputmethod.wetype` 找到输入法进程；
- 从该进程的 `AXWindows` 定位候选窗口；
- 读取静态文本节点及其 frame；
- 通过 `AXAttributedStringForRange` 读取前景亮度并识别高亮组；
- 样式不可用、亮度相同或多行候选时退回首候选或隐藏；
- 用宿主 App 的 `AXTextInputMarkedRange` 判断组合会话是否结束。

仍需持续验证的兼容边界：

- 哪个静态文本是当前蓝色高亮候选；
- 方向键切换后高亮项的身份；
- 鼠标悬停或鼠标切换后的身份；
- 微信升级后是否保留 `AXForegroundColor`；
- 浅色、深色主题及不同强调色下的亮度差；
- 单行短句、表情、翻页和展开候选；
- 微信内部候选列表中的选中索引。

方案不依赖屏幕截图、OCR、键盘事件监听或微信私有 IPC。样式无法判断时接受首候选
降级；其他第三方输入法只有在暴露 `InputMethodCandidateList` 时才使用首候选
降级，不扫描普通 `AXList`。

## 后续条件

当前已进入正式接入。微信升级后需要重新运行探针并回归：

1. 单行候选的序号、文字和 frame 配对；
2. 方向键和鼠标切换后的高亮跟随；
3. 浅色/深色主题；
4. 多行展开候选必须隐藏，不能压平成错误的一行；
5. 样式丢失时首候选兜底不会读取宿主 App 的其他静态文本。

如果微信后续提供原生 `AXSelected`、`AXFocused`、
`AXSelectedChildren` 或文档化候选接口，应优先替换亮度推断。
