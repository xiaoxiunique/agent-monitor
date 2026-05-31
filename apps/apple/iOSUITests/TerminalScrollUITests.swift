import XCTest

final class TerminalScrollUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTerminalTouchCaptureReceivesVerticalDrag() {
        let app = XCUIApplication()
        app.launchArguments.append("AGENT_MONITOR_TERMINAL_SCROLL_UITEST")
        if app.responds(to: Selector(("setShouldWaitForQuiescence:"))) {
            app.setValue(false, forKey: "shouldWaitForQuiescence")
        }
        app.launch()

        let capture = app.otherElements["terminal-touch-capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10), "Terminal touch capture overlay should be visible to UI tests.")
        XCTAssertEqual(capture.value as? String, "idle")

        let start = capture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let end = capture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        start.press(forDuration: 0.12, thenDragTo: end)

        let receivedScroll = NSPredicate(format: "value BEGINSWITH %@", "scroll:")
        expectation(for: receivedScroll, evaluatedWith: capture)
        waitForExpectations(timeout: 3)
    }
}
