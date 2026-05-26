import XCTest

/// UI smoke tests. We deliberately don't trigger a full /System scan in any
/// of these — `ScanControllerTests` in DarwinScanTests covers the scan
/// lifecycle directly. These tests just verify the chrome the user sees on
/// first launch and the welcome window's launcher controls.
///
/// **Note on save panels.** The new app flow opens a save panel before any
/// scan window appears — driving an `NSSavePanel` from XCUI is brittle and
/// would land a `.darwinscan` directory in the test runner's filesystem.
/// We therefore stop short of clicking through to a scan; per-document
/// chrome is covered by Swift Testing in `DarwinScanTests` instead.
final class DarwinScanUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testWelcomeWindowIsShownOnLaunch() throws {
        let app = launchedApp()
        // The welcome view's title — same string as the previous Untitled
        // doc's WelcomeView, but now hosted by the launcher window.
        XCTAssertTrue(
            app.staticTexts["DarwinScan"].waitForExistence(timeout: 5),
            "Welcome window should display the DarwinScan title"
        )
    }

    @MainActor
    func testWelcomeWindowExposesNewAndOpenButtons() throws {
        let app = launchedApp()
        // The welcome window's two launcher actions. Each button uses
        // `Label("New Scan…", ...)` / `Label("Open Scan…", ...)`; on
        // recent macOS the ellipsis is part of the accessibility label.
        // Match leniently so SDK drift doesn't bite.
        func buttonExists(_ name: String) -> Bool {
            let predicate = NSPredicate(format: "label BEGINSWITH %@", name)
            return app.buttons.matching(predicate).firstMatch.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(buttonExists("New Scan"),
                      "Welcome window should expose a 'New Scan' button")
        XCTAssertTrue(buttonExists("Open Scan"),
                      "Welcome window should expose an 'Open Scan' button")
    }

}
