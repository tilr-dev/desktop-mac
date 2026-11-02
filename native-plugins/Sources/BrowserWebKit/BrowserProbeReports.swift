import Foundation

/// State reports observed by the native browser probe, separate from view lifetime.
@MainActor
final class BrowserProbeReports {
    var events: [[String: Any]] = []
    private var onReport: (([String: Any]) -> Void)?

    func receive(_ detail: [String: Any]) {
        events.append(detail)
        onReport?(detail)
    }

    func last(_ id: String) -> [String: Any]? {
        events.last { $0["id"] as? String == id && $0["type"] == nil }
    }

    func discardedReport(_ id: String, timeout: TimeInterval) async -> [String: Any]? {
        func matches(_ detail: [String: Any]) -> Bool {
            detail["id"] as? String == id && detail["type"] == nil && detail["discarded"] as? Bool == true
        }
        if let report = last(id), matches(report) { return report }
        // The probe checks one view at a time. Subscribe without yielding between
        // the last-state check and registration, so a report cannot be missed.
        precondition(onReport == nil)
        return await withCheckedContinuation { continuation in
            let deadline = DispatchWorkItem { [weak self] in
                self?.onReport = nil
                continuation.resume(returning: nil)
            }
            onReport = { [weak self] detail in
                guard matches(detail) else { return }
                self?.onReport = nil
                deadline.cancel()
                continuation.resume(returning: detail)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
    }
}
