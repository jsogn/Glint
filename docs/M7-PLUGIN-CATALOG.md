# Glint M7 Plugin Catalog and Installation

- 日期：2026-10-20
- 目标：从可配置插件目录下载、校验、安装、更新和卸载插件

## 目录格式

目录是一个 JSON 文件，可以是远程 `https://` 地址，也可以是本地
`file://` 路径。支持两种格式：

```json
[
  { "id": "dict-cedict", "...": "PluginManifest 字段" }
]
```

或：

```json
{
  "plugins": [
    { "id": "dict-cedict", "...": "PluginManifest 字段" }
  ]
}
```

每个插件包含 `url`、`sha256`、版本、大小、许可证、语言和内存要求。

MLX 模型使用 `runtime: "mlx"` 和 Hugging Face 仓库 URL。安装器会读取仓库
snapshot、按 `revision` 固定版本并逐个文件下载；`sha256` 字段仅作为目录标识，
真实权重以 Hugging Face LFS SHA-256 为准。

模型下载默认按以下顺序尝试：

1. `GLINT_HF_ENDPOINT`（如显式配置）
2. `GLINT_HF_MIRROR`，默认 `https://hf-mirror.com`
3. `https://huggingface.co`

任一线路失败时都会清理当前临时结果并使用下一条线路重试。

`version` 是 Glint 插件接入包版本，不是上游模型版本，因此不在模型列表作为
模型身份展示。界面展示模型名、简介、安装体积和许可证；更新状态只显示“有新版本”。
翻译模型的介绍用一句自然文案说明速度、适用场景或配置建议；不单独设计速度等级，
也不在产品文案中写入某台开发机的 benchmark 毫秒数。

## 内部目录配置

插件目录是内部数据源，不暴露在用户界面。开发环境可以设置：

```bash
defaults write com.local.glint plugin.catalogURL -string \
  'https://example.com/glint/catalog.json'
```

或通过环境变量启动：

```bash
GLINT_PLUGIN_CATALOG_URL=https://example.com/glint/catalog.json \
  build/Build/Products/Debug/Glint.app/Contents/MacOS/Glint
```

## 安装流程

1. 拉取目录并展示可用插件；
2. ZIP 插件下载到临时目录，校验 SHA-256 后解压；
3. MLX 模型按 `revision` 从国内镜像或官方仓库下载 snapshot；
4. 校验模型文件；
5. 写入插件清单并替换本地插件目录；
6. 刷新真实安装状态。

下载失败、校验失败和解压失败都会保留已安装插件，不会破坏现有版本。
安装期间操作按钮会替换为线性进度条和“取消”文字按钮；取消会终止当前下载并清理临时目录。

## 插件页

- “翻译词典”“翻译模型”两个 Tab 展示对应插件；
- 目录中未安装或版本更新的插件会直接出现在对应卡片中；
- 下载进度、更新和安装错误都在对应位置展示。

## 开发测试

生成可下载目录：

```bash
./scripts/build_plugin_catalog.sh http://127.0.0.1:8765
python3 -m http.server 8765 --directory build/plugin-catalog
```

然后应用会从该目录读取支持项：

```text
http://127.0.0.1:8765/catalog.json
```

已安装的 OPUS-MT 会被打包并提供 SHA-256。
Qwen3 模型不打包 ZIP，而是由 App 从固定 revision 的 Hugging Face snapshot 下载。

CC-CEDICT、ECDICT 和 Wiktionary 是 App 内的只读核心词典，不通过插件目录
下载、安装或卸载。

## 当前限制

- 词典 ZIP 尚未部署正式公网目录；翻译模型可以直接从 Hugging Face snapshot 安装；
- 目前使用系统 ZIP 解压，后续需要增加更严格的归档路径校验；
- Qwen3 0.6B / 1.7B / 4B、Hy-MT2 1.8B 和 Index-Translate 2B 已进入内置目录，并在插件卡片中支持安装、卸载和切换。
