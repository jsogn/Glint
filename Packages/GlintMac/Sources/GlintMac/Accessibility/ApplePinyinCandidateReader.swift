import Foundation

struct ApplePinyinCandidateReader: AXCandidateReading {
    // Native candidate items include transparent vertical decoration that
    // should not add to the user-configured HUD spacing.
    private static let verticalVisualInset: CGFloat = 2.5

    let upstream: any AXCandidateReading

    var missReason: AXCandidateReadMissReason {
        upstream.missReason
    }

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        guard
            let candidate = upstream.snapshot(
                processIdentifier: processIdentifier,
                includeVisibleCandidates: includeVisibleCandidates,
                includeVisibleTexts: includeVisibleTexts
            )
        else {
            return nil
        }
        guard
            let geometry = candidate.geometry,
            geometry.verticalBounds.height
                > Self.verticalVisualInset * 2
        else {
            return candidate
        }
        let calibratedGeometry = AXCandidateGeometry(
            horizontalFrame: geometry.horizontalAnchor,
            horizontalSource: geometry.horizontalSource,
            verticalFrame: geometry.verticalBounds.insetBy(
                dx: 0,
                dy: Self.verticalVisualInset
            ),
            verticalSource: geometry.verticalSource
        )
        return AXCandidateSnapshot(
            text: candidate.text,
            visibleTexts: candidate.visibleTexts,
            options: candidate.options,
            frame: candidate.frame,
            candidateWindowFrame: candidate.candidateWindowFrame,
            candidateListFrame: candidate.candidateListFrame,
            geometry: calibratedGeometry,
            selectedIndex: candidate.selectedIndex,
            selectionIsExact: candidate.selectionIsExact
        )
    }
}
