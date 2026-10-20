import AppKit

@MainActor
enum LocalModelDirectoryPicker {
    static func chooseModelDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入 MLX 翻译模型"
        panel.message = "请选择包含 config.json、tokenizer 和 safetensors 权重的模型文件夹。"
        panel.prompt = "导入"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
