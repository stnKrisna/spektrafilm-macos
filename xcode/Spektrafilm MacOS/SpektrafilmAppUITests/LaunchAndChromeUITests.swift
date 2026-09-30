//
//  LaunchAndChromeUITests.swift
//  SpektrafilmAppUITests
//
//  Smoke tests for app launch, window chrome, toolbar, and empty state.
//

import XCTest

final class LaunchAndChromeUITests: SpektrafilmAppUITestCase {

    /// The app launches, shows its main window with the toolbar, the inspector
    /// panels, and the status bar.
    @MainActor
    func testLaunchShowsWindowToolbarAndInspector() throws {
        launchApp()

        // Toolbar buttons.
        waitFor("toolbar.openImage", ofType: .button)
        waitFor("toolbar.profiles", ofType: .button)
        waitFor("toolbar.export", ofType: .button)

        // Live preview is on by default, so no explicit Render button.
        XCTAssertFalse(element("toolbar.render", ofType: .button).exists)

        // Inspector panels (basic interface mode).
        waitFor("panel.film")
        waitFor("panel.print")
        waitFor("panel.light")
        waitFor("panel.character")
        waitFor("panel.detail")
        waitFor("panel.output")

        // Profile browsers inside the default-expanded Film panel.
        waitFor("profiles.film.browser")

        // Status bar is present.
        XCTAssertTrue(statusText.exists)

        attachScreenshot(named: "Launch - main window")
    }

    /// Without the test hook, no image is loaded: the empty-state placeholder
    /// is shown and Export is disabled.
    @MainActor
    func testEmptyStateWithoutImage() throws {
        launchAppWithoutImage()

        waitFor("toolbar.openImage", ofType: .button)

        // Empty-state placeholder.
        XCTAssertTrue(app.staticTexts["No Image"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Open a photograph to begin."].exists)

        // Nothing to export yet.
        let export = waitFor("toolbar.export", ofType: .button)
        XCTAssertFalse(export.isEnabled)

        // Zoom/compare controls are hidden until an image exists.
        XCTAssertFalse(element("preview.fit", ofType: .button).exists)
        XCTAssertFalse(element("preview.compare", ofType: .button).exists)

        attachScreenshot(named: "Empty state")
    }
}
