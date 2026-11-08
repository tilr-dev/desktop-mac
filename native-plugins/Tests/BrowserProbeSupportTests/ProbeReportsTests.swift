import XCTest
@testable import BrowserProbeSupport

final class ProbeReportsTests: XCTestCase {
    @MainActor
    func testDiscardReportQueuedAfterViewRelease() async {
        let reports = BrowserProbeReports()
        reports.receive(["id": "d1", "discarded": false, "canGoBack": true])
        // release() has already changed the view and freed its WKWebView, but
        // schedule() delivers its state on a later turn of the main queue.
        DispatchQueue.main.async {
            reports.receive(["id": "d1", "discarded": true, "canGoBack": true])
        }
        XCTAssertEqual(reports.last("d1")?["discarded"] as? Bool, false)
        let report = await reports.discardedReport("d1", timeout: 1)
        XCTAssertEqual(report?["discarded"] as? Bool, true)
        XCTAssertEqual(report?["canGoBack"] as? Bool, true)
    }

    @MainActor
    func testAlreadyDeliveredDiscardReport() async {
        let reports = BrowserProbeReports()
        reports.receive(["id": "d1", "discarded": true, "canGoBack": true])
        let report = await reports.discardedReport("d1", timeout: 0)
        XCTAssertEqual(report?["discarded"] as? Bool, true)
    }

    @MainActor
    func testOtherViewsAndBrowserEventsDoNotSatisfyWait() async {
        let reports = BrowserProbeReports()
        DispatchQueue.main.async {
            reports.receive(["id": "d2", "discarded": true])
            reports.receive(["id": "d1", "type": "open", "discarded": true])
            reports.receive(["id": "d1", "discarded": false])
            reports.receive(["id": "d1", "discarded": true, "canGoBack": true])
        }
        let report = await reports.discardedReport("d1", timeout: 1)
        XCTAssertEqual(report?["canGoBack"] as? Bool, true)
        XCTAssertNil(report?["type"])
    }

    @MainActor
    func testMissingDiscardReportTimesOutAndNextWaitCanSucceed() async {
        let reports = BrowserProbeReports()
        reports.receive(["id": "d1", "discarded": false])
        let missing = await reports.discardedReport("d1", timeout: 0)
        XCTAssertNil(missing)
        DispatchQueue.main.async { reports.receive(["id": "d1", "discarded": true]) }
        let report = await reports.discardedReport("d1", timeout: 1)
        XCTAssertEqual(report?["discarded"] as? Bool, true)
    }
}
