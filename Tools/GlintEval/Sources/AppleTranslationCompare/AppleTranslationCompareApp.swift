import AppKit
import Combine
import GlintEvalSupport
import SwiftUI
import Translation

@main
struct AppleTranslationCompareApp: App {
    @StateObject private var model: AppleTranslationEvaluationModel

    init() {
        let options = AppleTranslationEvaluationOptions(
            arguments: CommandLine.arguments
        )
        _model = StateObject(
            wrappedValue: AppleTranslationEvaluationModel(
                options: options
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            AppleTranslationEvaluationView(model: model)
                .translationTask(model.configuration) { session in
                    do {
                        let report =
                            try await AppleTranslationBenchmark
                            .run(
                                session: session,
                                options: model.options,
                                progress: { message in
                                    await model.setStatus(message)
                                }
                            )
                        model.finish(report: report)
                    } catch {
                        model.fail(error)
                    }
                }
                .task {
                    guard !model.hasStarted else { return }
                    try? await Task.sleep(
                        for: .milliseconds(300)
                    )
                    model.start()
                }
        }
        .defaultSize(width: 540, height: 260)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
private final class AppleTranslationEvaluationModel:
    ObservableObject
{
    let options: AppleTranslationEvaluationOptions

    @Published var configuration: TranslationSession.Configuration?
    @Published var status = "正在准备系统翻译语言包…"
    @Published var isRunning = false
    @Published var isFinished = false
    private(set) var hasStarted = false

    init(options: AppleTranslationEvaluationOptions) {
        self.options = options
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isRunning = true
        status = "正在请求系统翻译；如出现语言包下载提示，请确认。"
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "zh-Hans"),
            target: Locale.Language(identifier: "en")
        )
    }

    func setStatus(_ message: String) {
        status = message
    }

    func finish(report: AppleTranslationBenchmarkReport) {
        isRunning = false
        isFinished = true
        status =
            "对比完成：苹果 \(report.appleTranslation.top1)/"
            + "\(report.appleTranslation.total)，OPUS-MT "
            + "\(report.opusMT.top1)/\(report.opusMT.total)。"
        Task {
            try? await Task.sleep(for: .seconds(3))
            NSApplication.shared.terminate(nil)
        }
    }

    func fail(_ error: any Error) {
        isRunning = false
        status = "对比失败：\(error.localizedDescription)"
    }
}

private struct AppleTranslationEvaluationView: View {
    @ObservedObject var model: AppleTranslationEvaluationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("苹果系统翻译对比")
                        .font(.title2.weight(.semibold))
                    Text("简体中文 → 英文 · 同一批本地评测用例")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.status)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("完成后报告写入：\n\(model.options.outputPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
