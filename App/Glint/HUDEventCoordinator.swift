import CoreGraphics
import GlintCore
import GlintMac
import GlintUI
import OSLog

private let hudLatencyLogger = Logger(
    subsystem: "com.local.glint",
    category: "HUD"
)

@MainActor
final class HUDEventCoordinator {
    private let hud: HUDController
    private let model: MainWindowModel
    private var displayedRevision: UInt64?
    private var candidateChangedAt: ContinuousClock.Instant?

    init(hud: HUDController, model: MainWindowModel) {
        self.hud = hud
        self.model = model
    }

    func candidateChanged() {
        candidateChangedAt = .now
        hud.beginUpdate()
    }

    func updateSelection(index: Int, revision: UInt64) {
        guard model.displayPreferences.translationScope == .row else {
            return
        }
        guard displayedRevision == revision else { return }
        hud.updateSelection(itemID: index)
    }

    func layoutChanged(
        highlight: CandidateRegion,
        inputCaretRect: CGRect?
    ) {
        guard displayedRevision != nil else { return }
        hud.updateLayout(
            screenRect: highlight.cgRect,
            inputCaretRect: inputCaretRect
        )
    }

    func candidateEnded(immediate: Bool) {
        clear()
        hud.hide(animated: !immediate)
    }

    func show(
        translations: [CandidateTranslationPresentation],
        highlight: CandidateRegion,
        inputCaretRect: CGRect?,
        revision: UInt64,
        isProgressive: Bool,
        isMonitoring: Bool
    ) {
        guard isMonitoring else { return }
        // Progressive row results share one revision. Reject only results
        // older than the revision already on screen.
        if let displayedRevision, revision < displayedRevision {
            return
        }
        displayedRevision = revision
        model.statusText = ""
        let scope = model.displayPreferences.translationScope
        let items = Self.hudItems(
            translations: translations,
            scope: scope
        )
        hud.show(
            items: items,
            near: highlight.cgRect,
            inputCaretRect: inputCaretRect,
            layoutStyle:
                scope == .row
                ? .candidateRow
                : .selectedTranslations,
            position: model.displayPreferences.position,
            spacing: model.displayPreferences.candidateSpacing,
            opacity: model.displayPreferences.hudOpacity,
            appearance: model.displayPreferences.hudAppearance,
            revision: revision
        )
        let phase: String
        if scope == .row,
            items.count > 1,
            !isProgressive
        {
            phase = "row_visible"
        } else {
            phase = "selected_visible"
        }
        let eventToVisible =
            candidateChangedAt.map {
                Self.elapsedMilliseconds($0.duration(to: .now))
            } ?? 0
        hudLatencyLogger.debug(
            "perf latency phase=\(phase, privacy: .public) revision=\(revision, privacy: .public) visible_items=\(items.count, privacy: .public) event_to_visible_ms=\(eventToVisible, privacy: .public)"
        )
    }

    func clear() {
        displayedRevision = nil
        candidateChangedAt = nil
    }

    func hide(animated: Bool) {
        clear()
        hud.hide(animated: animated)
    }

    private static func elapsedMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func hudItems(
        translations: [CandidateTranslationPresentation],
        scope: CandidateTranslationScope
    ) -> [HUDItem] {
        switch scope {
        case .selected:
            guard
                let selected =
                    translations.first(where: \.isSelected)
                    ?? translations.first
            else {
                return []
            }
            let texts =
                selected.insertionOptions.isEmpty
                ? [selected.translation ?? "…"]
                : selected.insertionOptions
            return texts.enumerated().map { index, text in
                HUDItem(
                    id: index,
                    number: index + 1,
                    text: text,
                    isSelected: false
                )
            }
        case .row:
            return translations.map {
                HUDItem(
                    id: $0.index,
                    number: $0.index + 1,
                    text: $0.translation ?? "…",
                    isSelected: $0.isSelected
                )
            }
        }
    }
}
