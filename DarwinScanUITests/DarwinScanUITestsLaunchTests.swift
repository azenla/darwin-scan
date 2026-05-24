import XCTest

/// Launch screenshot suite — keeps a fresh screenshot of the welcome
/// state as a test attachment so visual regressions are easy to spot
/// without re-running the app by hand.
final class DarwinScanUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Dismiss the Open panel if DocumentGroup decided to show one
        // before reaching the welcome state.
        let openPanel = app.windows["Open"]
        if openPanel.waitForExistence(timeout: 2) {
            openPanel.buttons["Cancel"].click()
            app.menuBars.menus["File"].menuItems["New"].click()
        }

        // Wait for a known welcome-state element before snapping.
        _ = app.staticTexts["DarwinScan"].waitForExistence(timeout: 5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
