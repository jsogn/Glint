# Glint M14 Model Plugin Lifecycle

- 日期：2026-10-21
- 目标：修复 OPUS 插件加载、选择失败状态和卸载生命周期
- 2026-10-22 起：OPUS-MT 改为随 App 提供的只读基础模型；以下关于 OPUS
  插件目录、卸载和 catalog 安装的规则仅保留为历史迁移背景。可选 MLX 模型
  继续使用插件生命周期。

## 根因

OPUS 的旧开发安装目录为 `opus-ct2-int8`，但清单 ID 为
`mt-opus-zh-en`。插件管理器按 ID 拼接目录，因此：

- 加载时读取不存在的 `plugins/mt-opus-zh-en/model`；
- 卸载时删除不存在的 `plugins/mt-opus-zh-en`；
- 删除操作表面成功，刷新后旧目录又被扫描回来。

UI 在模型加载前就提交选择，因此加载失败后仍显示“使用中”。

## 当前规则

- 插件目录名必须等于 manifest ID；不再提供旧目录兼容。
- OPUS 唯一路径为 `plugins/mt-opus-zh-en`。
- 模型选择只有加载成功后才成为当前模型；失败时回滚到上一个模型。
- 失败状态显示在尝试加载的模型行，不显示为“使用中”。
- 卸载前释放对应翻译运行时，再删除插件并重新扫描。
- 删除不存在的插件会明确报错，不再静默成功。
- 移除隐式 CTranslate2 fallback；当前选择的模型不可用时直接报告错误。
- CTranslate2 初始化错误包含缺失路径、动态库、桥接符号或模型加载原因。
- OPUS 模型和 CTranslate2 动态库进入 App bundle，并在启动迁移时删除旧
  Application Support 插件副本。
- OPUS 权重不进入 Git；构建前由 `scripts/prepare_opus_model.sh` 从固定
  Hugging Face revision 转换为 CTranslate2 int8，并按 lock 文件校验。
- 其他翻译模型继续使用 catalog 下载、安装、切换和卸载。
- 模型选择不显示“推荐”标签；没有翻译模型时，使用中性的“启用句子翻译”
  引导卡，让用户安装离线模型、导入本地模型或配置在线接口。
- 版本检测使用数字分段比较，`1.10.0 > 1.9.9`，且 `1.0 == 1.0.0`。
- 只有 catalog 版本高于已安装版本时才显示“可更新”和
  `当前版本 → 新版本`。
- 已安装和可下载模型的信息行统一显示
  `版本 X · 大小 · 许可证`；本地导入模型显示“本地导入”。
- App 启动约 2 秒后自动静默检查 catalog；进入模型页时按冷却时间补查，
  不再要求用户主动点击。
- catalog 成功检查后 6 小时内不重复请求；失败后 15 分钟内不重试。
- 网络检查使用 `ETag` / `Last-Modified` 条件请求，未变化时接受 `304`。
- 自动检查失败时保留现有模型列表，不显示阻塞式错误。
- 更新先保留旧插件目录；使用中的翻译模型成功加载新版本后才提交更新。
  新版本加载失败时恢复旧目录并重新加载旧版本。

手动准备内置 OPUS：

```bash
./scripts/prepare_opus_model.sh
```

## 运行验证

- 内置 OPUS 可以加载并翻译短句。
- 缺失 CTranslate2 模型时返回包含实际路径的错误。
- 可选模型激活失败后恢复原模型，失败项仍可卸载。
- 卸载会调用运行时释放动作，并删除 manifest ID 对应目录。
- 从开发 catalog 安装可选模型到临时目录后，目录结构、SHA256 和动态库
  加载均通过验证。
- `GlintPlugins` 15 个测试通过，`GlintUI` 14 个测试通过；覆盖语义版本
  比较、更新提示、条件请求、检查冷却、插件提交/回滚以及使用中翻译模型
  更新失败恢复。
- 干净构建会先准备内置 OPUS，再生成包含模型和动态库的 Debug App。

## OPUS 构建产物

- `model-lock.json` 固定 Hugging Face revision、转换工具版本、量化方式和
  每个产物的 SHA256。
- `prepare_opus_model.py` 下载原始 Transformers 模型并转换为 CTranslate2
  int8，产物写入 Git 忽略的 `Resources/Plugins/mt-opus-zh-en/model`。
- `scripts/build.sh` 和 `scripts/test.sh` 自动调用准备脚本；模型未变化时只做
  SHA256 校验，不重复转换。
