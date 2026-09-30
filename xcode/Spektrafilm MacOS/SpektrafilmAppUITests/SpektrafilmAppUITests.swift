//
//  SpektrafilmAppUITests.swift
//  SpektrafilmAppUITests
//
//  Created by Stanislaus Krisna on 12/9/2026.
//
//  General smoke tests. Feature-specific E2E coverage lives in:
//  - LaunchAndChromeUITests
//  - ImageAndProfilesUITests
//  - AdjustmentsAndRenderUITests
//  - ZoomAndCompareUITests
//  - ExportSheetUITests
//  - SettingsUITests
//

import XCTest

final class SpektrafilmAppUITests: SpektrafilmAppUITestCase {

    /// The app launches with the test hook, loads the synthetic image, renders
    /// it, and stays responsive.
    @MainActor
    func testLaunchLoadAndRenderSmoke() throws {
        launchApp()
        waitForImageLoaded()
        waitForRenderComplete()

        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertTrue(element("toolbar.export", ofType: .button).isEnabled)
        attachScreenshot(named: "Smoke - rendered")
    }

    /// Measures how long it takes to launch the application.
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
