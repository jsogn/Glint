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

## 安装与升级

Debug 构建中打开“输入法支持”页。检测到 Rime 和已部署方案后，用户点击
“安装支持”并确认；安装不完整时显示“重新安装”。首次安装不会自动发生。

安装器只执行以下操作：

1. 读取 Squirrel 共享配置和用户 `default.custom.yaml`，确定 `schema_list`。
2. 与 `~/Library/Rime/build/*.schema.yaml` 取交集，只处理已启用且已编译方案。
3. 预检所有目标 `.custom.yaml`；任一配置不能安全合并时，在任何写操作前停止。
4. 比较目标内容，只写入真正变化的文件；已完整安装时直接返回，不重写或重新部署。
5. 为现有文件保留首次安装前的字节级原件、权限和 SHA256；后续修复继续沿用该原件。
6. 写入事务日志和事务快照，再原子写入 Lua、helper 和受管 schema 配置。
7. 写入包含协议版本、schema ID、文件 SHA256、备份和新建文件清单的 manifest。
8. 运行 `Squirrel --reload`；超过 15 秒会终止该部署进程并进入回滚。
9. 成功后提交事务；任一步失败时恢复全部快照并再次部署恢复后的配置。

重复修复是幂等的。安装器会保留首次安装前的备份和“文件由安装器创建”的语义，
避免第二次修复后再卸载留下空 `.custom.yaml`。

安装、修复、迁移和卸载由进程内锁和跨进程文件锁串行化。写入目标前还会再次核对
内容与权限；如果用户在操作期间修改了文件，本次操作停止并回滚。进程在写文件期间
退出时，下次 Debug 启动会读取事务日志：未提交事务自动恢复，已提交事务只做收尾。
如果崩溃后用户又编辑了同一文件，当前内容既不等于事务前状态，也不等于本事务
允许写入的状态，恢复会停止并保留现场，不会用旧快照覆盖用户的新改动。

未变化的目标不会被重写。安装后修改过的受管 helper、Lua 或 schema 配置不会被自动
迁移覆盖；界面会要求手动处理。安装器自己创建后又被删除的文件可以安全补建。

候选读取支持使用独立的 `assetVersion`，不与 Glint App 版本绑定。App 更新后，
Debug 构建只在已存在安装记录且资源版本或协议版本变化时自动迁移；仅修改 UI、
词典或翻译功能不会触发插件重装。从未安装过候选读取支持的用户不会被自动写入
Rime 配置。修改 Lua、relay 或桥接协议时必须增加该资源版本。迁移复用安装事务，
复杂 YAML 会在写入前停止。

托管位置：

```text
~/Library/Application Support/Glint/RimeCandidateLab/
  ├── RimeCandidateBridge
  ├── install-manifest.json
  ├── pending-install-transaction.json   # 仅事务期间存在
  ├── Transactions/<UUID>/                # 仅事务期间存在
  ├── Backups/<UUID>/
  └── .rime-install.lock

~/Library/Rime/lua/glint/
  ├── candidate_bridge.lua
  └── json.lua
```

helper 权限为 `0700`，Socket 权限为 `0600`。安装器不会下载可执行代码；helper
和 Lua 都来自已签名的 Debug App bundle。

备份目录权限为 `0700`，备份文件、manifest 和事务文件权限为 `0600`。manifest
记录备份 SHA256 和原文件权限，恢复前会重新校验。路径使用解析符号链接后的真实
路径检查，并限制在明确允许的 helper、Lua、schema 和 manifest 目标内；目标或
备份路径的符号链接、越界父目录和不相关 Rime 文件都会被拒绝。

UTF-8 BOM 会原样保留。当前自动编辑器只接受 LF 文本和严格支持的 YAML 子集；
CRLF、重复 `patch`、anchor/alias、merge key、Rime `__include`、文档分隔符、
嵌套 `engine`、inline filter list、带缩进的 tab 或其他不确定结构会停止自动
安装，要求手动合并。

“卸载”优先恢复 manifest 记录的原文件，删除安装器创建的受管文件，再重新部署。
manifest 损坏时退回保守清理路径：只删除 Glint 专用 helper/Lua 路径，并只移除
完整、精确匹配的受管 filter 标记。
如果安装后用户修改了受管文件，卸载会在写入前停止，避免覆盖用户的新配置。
`RimeCandidateBridge` 和 `lua/glint/*.lua` 位于 Glint 专用路径，即使安装前已存在
旧研究版本，也会在卸载末尾作为托管组件移除，不能恢复成残留文件。

无 manifest 的回退清理只移除完整、精确匹配且位于
`patch -> engine/filters/+` 下的 Glint 管理块；它不会删除 `.custom.yaml`，也不会
删除用户原有的 filter、注释或空键。损坏、不完整或位置不正确的管理标记会停止操作。

filter 识别按完整 YAML 标量比较，不使用子串。用户原先手动配置的同一个 filter
不计入安装器所有权，卸载时保持原样；如果用户之后决定彻底移除 Glint，需要按手动
安装说明自行删除这一行。

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
- 使用 anchor、alias、merge key、`__include` 或其他会改变有效合并结果的结构；
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

- 用户主动安装后，状态从“未安装”切换到“已安装”。
- 当前机器只写入 `luna_pinyin`、`luna_pinyin_simp`、
  `luna_pinyin_fluency`，没有写入未启用的 `luna_quanpin`。
- 安装后 helper 和两份 Lua 与 App bundle 的 SHA256 一致，helper 权限为
  `0700`，manifest 文件权限为 `0600`。
- Squirrel 重新部署后旧 relay 进程退出，没有残留多实例。
- 隔离用户目录的 headless 引擎测试返回 5 个候选；模拟向下选择后页内索引由
  `0` 变为 `1`。
- 单元测试覆盖安全 YAML 合并、启用方案过滤、事务回滚、重复修复、损坏
  manifest 清理、helper 权限、用户改动冲突、并发 session 竞争和协议版本修复。
- 安全回归还覆盖：重复安装不重写、原件跨重装保留、手动 filter 不被卸载删除、
  子串误匹配、损坏备份、损坏事务、崩溃后用户再次编辑、符号链接越界、并发安装、
  BOM、CRLF 和 `安装 -> 重装 -> 卸载` 的字节级恢复。

## 已知限制

- Lua、Squirrel AX 和 CGWindow 都不提供逐候选屏幕 frame。Reader 优先尝试候选
  面板 frame，拿不到时对鼠须管回退到宿主输入光标；HUD 只能贴近输入位置，不能
  保证与候选栏逐项对齐。
- 复杂 Rime 配置仍需要手动合并。自动安装宁可停止，也不猜测用户 YAML。
- CRLF 或包含 anchor/include/merge 的配置目前只能手动安装。
- 仍需继续验证多显示器、不同缩放、浅色/深色、分页和更多宿主 App。

## 发布前真实验收

真实 Squirrel 行为不能完全由单元测试替代。每次准备发布包含 Rime 支持的构建前，
必须在干净的 Debug 安装上完成以下验收：

1. 记录 `~/Library/Rime` 中受管文件的内容哈希和权限；启动
   `./scripts/dev.sh`，确认未安装用户没有自动写入 Rime 配置。
2. 主动点击“安装支持”，确认状态变为“已安装”；应用和 Squirrel 重启后仍能读取
   候选。
3. 输入单词、短语和短句，核对蓝色高亮候选与实际译文完全一致，不能出现只截取
   半个候选、第一个候选代替当前候选或旧候选残留。
4. 测试单候选、整页候选、翻页以及页首/页中/页尾选择；每次选择后
   `selectedText` 和 `selectedIndex` 必须一致。
5. 切换简繁、中西文标点、全半角和 ASCII 模式，确认模式切换不会留下旧快照。
6. 提交候选、按 Escape、移焦和切换输入法后，HUD 与候选快照都必须结束。
7. 切换到 Apple 拼音、微信输入法和搜狗，确认不会消费 Rime 快照或改变原有
   Reader 路由。
8. 在密码框、终端安全输入和其他 Secure Input 场景确认不出现 HUD、不读取候选。
9. 执行“重新安装”，确认无变化文件没有被重写，reload 只在实际内容变化时发生。
10. 执行“卸载”，确认受管文件恢复后哈希和权限与安装前一致，受管 helper/Lua、
    Socket、事务日志和锁文件均清理。
11. 使用一个复杂 YAML 样例确认安装器会转为手动配置，不能在未确认结构上写入。
12. 检查浅色、深色、窗口缩放、多显示器和无候选面板 frame 的 HUD 位置。

Release 产物还必须确认 `Contents/Helpers/RimeCandidateBridge` 和
`Contents/Resources/RimeCandidateBridge` 均不存在。

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
