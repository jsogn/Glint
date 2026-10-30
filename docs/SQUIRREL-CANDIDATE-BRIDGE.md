# Rime 输入法支持（Squirrel）

- 状态：实验，协议 v3
- 验证环境：macOS 26、Squirrel 1.1.2、Apple Silicon
- 产品边界：仅 Debug 构建提供安装入口和候选接收器

## 背景

原版鼠须管把候选绘制在一个不可编辑、不可选择的 `NSTextView` 中。候选窗的
Accessibility 树只有一个 `AXTextArea`：

- 没有候选级 AX 子节点。
- `AXValue` 和 `AXSelectedText` 为空。
- `AXSelectedTextRange` 无法表达当前候选。
- `AXStringForRange` 和 `AXAttributedStringForRange` 对候选范围返回错误。

因此标准 AX Reader 无法稳定读取鼠须管的当前高亮候选。

Squirrel 随包提供 `librime-lua`。Glint 通过用户侧 Lua filter 从 Rime 引擎取得
最终候选页和页内选中索引，再用一个只连接本机 Unix Domain Socket 的 helper
把数据转交给 Debug App。这不修改 Squirrel 官方仓库或
`/Library/Input Methods/Squirrel.app`。

## 数据流

```text
Squirrel / librime-lua
  └─ glint.candidate_bridge
       └─ RimeCandidateBridge relay
            └─ user-only Unix domain socket
                 └─ RimeCandidateBridgeReceiver
                      └─ SquirrelCandidateReader
```

协议 v3 携带：

- `selectedText` 和页内 `selectedIndex`；
- 当前候选页；
- `sessionID`、单调递增的 `sequence` 和 heartbeat；
- schema ID、活动状态和协议版本。

全局选中索引会先折算成页内索引，因此翻页后仍能定位当前候选。旧 session 的
报文、旧 sequence 和无法与当前快照匹配的心跳都会被拒绝；旧 session 的结束
报文也不能清空新 session 的当前候选。

## 一键安装

Debug 构建中打开“输入法支持”页。检测到 Rime 和已部署方案后，选择“一键启用”；
安装不完整或升级后哈希不一致时显示“修复安装”。

安装器只执行以下操作：

1. 读取 Squirrel 共享配置和用户 `default.custom.yaml`，确定 `schema_list`。
2. 与 `~/Library/Rime/build/*.schema.yaml` 取交集，只处理已启用且已编译方案。
3. 预检所有目标 `.custom.yaml`；任一配置不能安全合并时，在任何写操作前停止。
4. 为将要覆盖的文件创建带时间戳的备份目录。
5. 原子写入 Lua、helper 和受管 schema 配置。
6. 写入包含协议版本、schema ID、文件 SHA256、备份和新建文件清单的 manifest。
7. 运行 `Squirrel --reload`。
8. 任一步失败时恢复全部快照；重新部署失败也会完整回滚。

重复修复是幂等的。安装器会保留首次安装前的备份和“文件由安装器创建”的语义，
避免第二次修复后再卸载留下空 `.custom.yaml`。

托管位置：

```text
~/Library/Application Support/Glint/RimeCandidateLab/
  ├── RimeCandidateBridge
  ├── install-manifest.json
  └── Backups/<UUID>/

~/Library/Rime/lua/glint/
  ├── candidate_bridge.lua
  └── json.lua
```

helper 权限为 `0700`，Socket 权限为 `0600`。安装器不会下载可执行代码；helper
和 Lua 都来自已签名的 Debug App bundle。

“卸载”优先恢复 manifest 记录的原文件，删除安装器创建的受管文件，再重新部署。
manifest 损坏时仍可退回到“只删除已知哈希和精确 filter 标记”的安全清理路径。
如果安装后用户修改了受管文件，卸载会在写入前停止，避免覆盖用户的新配置。
`RimeCandidateBridge` 和 `lua/glint/*.lua` 位于 Glint 专用路径，即使安装前已存在
旧研究版本，也会在卸载末尾作为托管组件移除，不能恢复成残留文件。

## 启用方案选择

安装器不把 `build/` 下所有 schema 都视为启用方案。它按以下顺序计算目标：

1. 优先读取
   `Squirrel.app/Contents/SharedSupport/build/default.yaml`，缺失时回退到同目录的
   `default.yaml`。
2. 读取 `~/Library/Rime/default.custom.yaml` 中简单的 `schema_list:` 替换或
   `schema_list/+:` 追加。
3. 与已编译 schema 求交集，并保持 Rime 配置顺序。

以下情况停止自动安装并要求手动配置：

- `schema_list` 使用无法安全解释的嵌套或 inline 结构；
- 未知 `schema_list` patch 操作；
- 目标 `.custom.yaml` 使用嵌套 `engine:`、inline filter list 或其他未支持结构。

这样可以避免更新一个输入法后误写到用户未启用的方案，也避免猜测复杂 YAML
的合并语义。

## 隔离与隐私

- 只有 Debug 构建显示“输入法支持”页、启动 Socket 接收器和构造安装器。
- Release 构建不注册 Squirrel Reader、不启动 Socket、不执行安装。
- 只有当前 TIS 输入源是 `im.rime.inputmethod.Squirrel` 时才使用该 Reader。
- Apple 拼音、微信、搜狗和未知输入法的 Reader 路由不变。
- 候选文字只经过进程管道和用户专属 Socket，不写入 manifest、文件或 OSLog。
- Glint 不读取输入框正文，不安装键盘事件监听，不截图。
- 运行本机 Lua 扩大了输入法进程的信任边界，因此安装必须由用户显式确认并可
  完整卸载。

## 已验证

- 一键安装从“需要修复”切换到“已启用”。
- 当前机器只写入 `luna_pinyin`、`luna_pinyin_simp`、
  `luna_pinyin_fluency`，没有写入未启用的 `luna_quanpin`。
- 安装后 helper 和两份 Lua 与 App bundle 的 SHA256 一致，helper 权限为
  `0700`，manifest 文件权限为 `0600`。
- Squirrel 重新部署后旧 relay 进程退出，没有残留多实例。
- 隔离用户目录的 headless 引擎测试返回 5 个候选；模拟向下选择后页内索引由
  `0` 变为 `1`。
- 单元测试覆盖安全 YAML 合并、启用方案过滤、事务回滚、重复修复、损坏
  manifest 清理、helper 权限、用户改动冲突、并发 session 竞争和协议版本修复。

## 已知限制

- Lua、Squirrel AX 和 CGWindow 都不提供逐候选屏幕 frame。Reader 优先尝试候选
  面板 frame，拿不到时对鼠须管回退到宿主输入光标；HUD 只能贴近输入位置，不能
  保证与候选栏逐项对齐。
- 复杂 Rime 配置仍需要手动合并。自动安装宁可停止，也不猜测用户 YAML。
- 仍需继续验证多显示器、不同缩放、浅色/深色、分页和更多宿主 App。

## 手动备用安装

仅在自动安装明确提示“需要手动配置”时使用。先备份目标
`<schema>.custom.yaml`，再把 filter 合并到现有 `patch:` 中：

```yaml
patch:
  engine/filters/@before 0: lua_filter@*glint.candidate_bridge
```

Debug App 内的资源位于：

```text
Glint.app/Contents/Helpers/RimeCandidateBridge
Glint.app/Contents/Resources/RimeCandidateBridge/candidate_bridge.lua
Glint.app/Contents/Resources/RimeCandidateBridge/json.lua
```

开发实验也可以从 `Tools/RimeCandidateLab` 构建并手动复制。保存配置后运行：

```bash
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload
```

手动配置步骤与实验室工具说明见
[RimeCandidateLab](../Tools/RimeCandidateLab/README.md)。
