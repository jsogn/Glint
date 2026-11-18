import Foundation

@MainActor
protocol InputSourceReading: Sendable {
    func currentInputSource() -> ActiveInputSource
}

extension InputSourceMonitor: InputSourceReading {}

protocol FocusReading {
    func snapshot() -> FocusSnapshot?
    func processFallbackSnapshot() -> FocusSnapshot?
}

extension FocusReading {
    func processFallbackSnapshot() -> FocusSnapshot? {
        nil
    }
}

extension FocusMonitor: FocusReading {}

extension AXCandidateReader: AXCandidateReading {}
