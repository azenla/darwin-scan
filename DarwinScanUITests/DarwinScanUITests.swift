import XCTest

/// UI smoke tests. We deliberately don't trigger a full /System scan in
/// any of these — `ScanControllerTests` in DarwinScanTests covers the
/// scan lifecycle directly. These tests just verify the chrome the user
/// sees on first launch.
final class DarwinScanUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch the app and bring an untitled document window to the front
    /// by routing through File > New. DocumentGroup may also pop the
    /// "Open Recent" panel on launch; this helper closes that path.
    @MainActor
    private func launchedAppWithNewDocument() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // If an open panel comes up first, dismiss it before requesting a
        // new document.
        let openPanel = app.windows["Open"]
        if openPanel.waitForExistence(timeout: 2) {
            openPanel.buttons["Cancel"].click()
        }
        // SwiftUI may auto-open a new document, or it may not — be
        // defensive and route through File > New when no window is up.
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.menuBars.menus["File"].menuItems["New"].click()
        }
        return app
    }

    @MainActor
    func testWelcomeViewIsShownOnFirstLaunch() throws {
        let app = launchedAppWithNewDocument()
        // Welcome view headline.
        XCTAssertTrue(
            app.staticTexts["DarwinScan"].waitForExistence(timeout: 5),
            "Welcome view should display the DarwinScan title"
        )
        // The primary CTA — Welcome view's Label("Run System Scan", ...)
        // shows as either a button (text label) or a static text fallback,
        // depending on macOS version + a11y settings.
        XCTAssertTrue(
            app.buttons["Run System Scan"].exists ||
            app.staticTexts["Run System Scan"].exists,
            "Welcome view should expose a Run System Scan button"
        )
    }

    @MainActor
    func testSidebarListsCategoryLabels() throws {
        let app = launchedAppWithNewDocument()
        // Snap a debug screenshot — the SwiftUI sidebar's accessibility
        // tree changes between SDK versions and this attachment is the
        // breadcrumb if the assertions below ever start missing rows.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Sidebar"
        shot.lifetime = .keepAlways
        add(shot)

        // Try the most resilient query path: a label-string predicate
        // against any element. SwiftUI's `Label` widget exposes its text
        // as an accessibility label on macOS, but the element type may be
        // staticText / button / cell / outlineRow depending on layout.
        func sidebarLabelExists(_ label: String, timeout: TimeInterval = 5) -> Bool {
            let predicate = NSPredicate(
                format: "label == %@ OR title == %@ OR identifier == %@",
                label, label, label
            )
            let element = app.descendants(matching: .any)
                .matching(predicate)
                .firstMatch
            return element.waitForExistence(timeout: timeout)
        }
        // We only assert on the existence of *some* category as a
        // smoke check; UI-tree mapping for sidebar labels varies enough
        // between macOS versions that exhaustive matching is fragile.
        let candidates = ["System Info", "All Items", "Executables",
                          "Applications", "Frameworks & Libraries"]
        let found = candidates.contains { sidebarLabelExists($0, timeout: 2) }
        XCTAssertTrue(found,
                      "Sidebar should expose at least one navigable section label")
    }

    @MainActor
    func testToolbarHasScanButton() throws {
        let app = launchedAppWithNewDocument()
        // The Scan toolbar item uses Label("Scan", systemImage: "magnifyingglass").
        XCTAssertTrue(
            app.buttons["Scan"].waitForExistence(timeout: 5),
            "Toolbar should expose a Scan button"
        )
    }

    @MainActor
    func testClickingScanOpensTheOptionsSheet() throws {
        let app = launchedAppWithNewDocument()
        let scanButton = app.buttons["Scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5))
        scanButton.click()
        // Options sheet's title.
        XCTAssertTrue(
            app.staticTexts["New Scan"].waitForExistence(timeout: 3),
            "Clicking Scan should present the New Scan options sheet"
        )
        // The Roots GroupBox should list the default scan roots.
        XCTAssertTrue(app.staticTexts["/System"].exists)
        XCTAssertTrue(app.staticTexts["/bin"].exists)
        // Cancel out without starting a scan — we don't want a full
        // /System walk in CI.
        app.buttons["Cancel"].click()
    }

    @MainActor
    func testHashFilesToggleIsPresentInOptions() throws {
        let app = launchedAppWithNewDocument()
        app.buttons["Scan"].click()
        XCTAssertTrue(app.staticTexts["New Scan"].waitForExistence(timeout: 3))
        // Toggles inside the sheet show up as XCUI switches/checkboxes
        // with the toggle label as their accessibility identifier.
        let toggleQuery = app.checkBoxes["Hash every file (SHA-256)"]
        XCTAssertTrue(
            toggleQuery.exists || app.switches["Hash every file (SHA-256)"].exists,
            "Inspection group should expose the SHA-256 toggle"
        )
        app.buttons["Cancel"].click()
    }
}
