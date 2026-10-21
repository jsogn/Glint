import AppKit
import Darwin
import Foundation
import GlintMac

enum AXCandidateProbe {
    private static let pollIntervalMicroseconds: useconds_t = 40_000

    static func run() -> Never {
        let seconds = probeSeconds()
        let targetPID = probePID()
        let reader = AXCandidateReader()
        let focus = FocusMonitor()
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(seconds * 1_000_000_000)
        var latencies: [Double] = []
        var lastState = ""

        print(
            "probe accessibility=\(FocusMonitor.isAccessibilityTrusted()) "
                + "seconds=\(seconds)"
        )
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let candidate = reader.snapshot(processIdentifier: targetPID)
            let elapsed = Double(
                DispatchTime.now().uptimeNanoseconds - startedAt
            ) / 1_000_000
            latencies.append(elapsed)

            let frontmost = NSWorkspace.shared.frontmostApplication
            let frontmostName = frontmost?.localizedName ?? "<none>"
            let focusSnapshot = focus.snapshot()
            let state = [
                frontmostName,
                candidate?.text ?? "<none>",
                String(describing: focusSnapshot?.compositionState),
            ]
            .joined(separator: "|")
            if state != lastState {
                let detailedCandidate: AXCandidateSnapshot?
                if candidate != nil {
                    detailedCandidate = reader.snapshot(
                        processIdentifier: targetPID,
                        includeVisibleCandidates: true
                    )
                } else {
                    detailedCandidate = nil
                }
                print(
                    "probe front=\(frontmostName) "
                        + "targetPID=\(targetPID.map(String.init) ?? "<frontmost>") "
                        + "composition="
                        + "\(String(describing: focusSnapshot?.compositionState)) "
                        + "candidate=\(candidate?.text ?? "<none>") "
                        + "visible=\(detailedCandidate?.visibleTexts ?? []) "
                        + "frame=\(candidate?.frame.map { String(describing: $0) } ?? "<none>") "
                        + "windowFrame=\(candidate?.candidateWindowFrame.map { String(describing: $0) } ?? "<none>") "
                        + "listFrame=\(candidate?.candidateListFrame.map { String(describing: $0) } ?? "<none>") "
                        + "latencyMs=\(String(format: "%.3f", elapsed))"
                )
                lastState = state
            }
            usleep(pollIntervalMicroseconds)
        }

        if !latencies.isEmpty {
            latencies.sort()
            let median = latencies[latencies.count / 2]
            let p95 = latencies[
                min(latencies.count - 1, Int(Double(latencies.count) * 0.95))
            ]
            print(
                "summary samples=\(latencies.count) "
                    + "p50Ms=\(String(format: "%.3f", median)) "
                    + "p95Ms=\(String(format: "%.3f", p95)) "
                    + "maxMs=\(String(format: "%.3f", latencies.last ?? 0))"
            )
        }
        exit(0)
    }

    private static func probeSeconds() -> Double {
        let raw = ProcessInfo.processInfo.environment[
            "GLINT_AX_PROBE_SECONDS"
        ]
        let value = raw.flatMap(Double.init) ?? 20
        return min(max(value, 1), 120)
    }

    private static func probePID() -> pid_t? {
        guard let raw = ProcessInfo.processInfo.environment[
            "GLINT_AX_PROBE_PID"
        ], let pid = Int32(raw) else {
            return nil
        }
        return pid
    }
}
