//
//  ZoomAndCompareUITests.swift
//  SpektrafilmAppUITests
//
//  Covers the preview zoom controls (Fit / 1:1 / +/-) and the compare toggle.
//

import XCTest

final class ZoomAndCompareUITests: SpektrafilmAppUITestCase {

    private var zoomLabel: String? {
        app.staticTexts["preview.zoomLabel"].value as? String
    }

    @MainActor
    func testZoomControls() throws {
        launchApp()
        waitForImageLoaded()

        let fit = waitFor("preview.fit", ofType: .button)
        let oneToOne = waitFor("preview.oneToOne", ofType: .button)
        let zoomIn = waitFor("preview.zoomIn", ofType: .button)
        let zoomOut = waitFor("preview.zoomOut", ofType: .button)

        // Starts in Fit.
        XCTAssertEqual(zoomLabel, "Fit")

        // 1:1 shows 100%.
        oneToOne.click()
        XCTAssertEqual(zoomLabel, "100%")

        // Back to Fit.
        fit.click()
        XCTAssertEqual(zoomLabel, "Fit")

        // Zoom in from Fit goes to 100%.
        zoomIn.click()
        XCTAssertEqual(zoomLabel, "100%")

        // Zoom out from 100% steps down to 66.7% → "67%".
        zoomOut.click()
        XCTAssertEqual(zoomLabel, "67%")
    }

    /// Click compare at 1:1 must show a visibly different (unedited) preview,
    /// then restore the render when toggled back.
    @MainActor
    func testCompareAtOneToOneShowsOriginal() throws {
        launchApp(compareMode: "click")
        waitForRenderComplete()
        waitFor("preview.oneToOne", ofType: .button).click()

        let render = try XCTUnwrap(waitForStablePreview(), "Should capture the rendered 1:1 preview")
        attachScreenshot(named: "Compare 1:1 - render")

        let compare = waitFor("preview.compare", ofType: .button)
        XCTAssertEqual(compare.label, "Compare")
        compare.click()
        XCTAssertEqual(compare.label, "Show Render")

        let original = try XCTUnwrap(waitForStablePreview(), "Should capture the original 1:1 preview")
        attachScreenshot(named: "Compare 1:1 - original")

        XCTAssertGreaterThan(fractionDifferent(render, original), 0.05,
                             "Click compare at 1:1 must show a visibly different original")

        compare.click()
        let restored = try XCTUnwrap(waitForStablePreview(), "Should capture the restored render")
        XCTAssertLessThan(fractionDifferent(render, restored), 0.03,
                          "Toggling compare back must restore the render")
    }

    /// Before/after slider at 1:1: the left half shows the original, the right
    /// half keeps the render.
    @MainActor
    func testSliderAtOneToOneShowsOriginalLeftRenderRight() throws {
        launchApp(compareMode: "beforeAfterSlider")
        waitForRenderComplete()
        waitFor("preview.oneToOne", ofType: .button).click()

        let render = try XCTUnwrap(waitForStablePreview(), "Should capture the rendered 1:1 preview")

        waitFor("preview.compare", ofType: .button).click()
        let slider = try XCTUnwrap(waitForStablePreview(), "Should capture the slider preview")
        attachScreenshot(named: "Compare 1:1 - slider")

        let leftDiff = fractionDifferent(render, slider, xRange: 0.05...0.45)
        let rightDiff = fractionDifferent(render, slider, xRange: 0.55...0.95)
        XCTAssertGreaterThan(leftDiff, 0.05, "Slider left (original) must differ from the render")
        XCTAssertLessThan(rightDiff, 0.03, "Slider right (render) must match the render")
    }

    /// Best-effort hold compare: the press must complete cleanly and release
    /// back to the Compare label. Mid-press pixels cannot be captured reliably
    /// through XCUI, so the compare rendering itself is covered by the click
    /// test and the ViewportService unit tests.
    @MainActor
    func testHoldCompareReleasesCleanly() throws {
        launchApp(compareMode: "hold")
        waitForRenderComplete()
        waitFor("preview.oneToOne", ofType: .button).click()
        _ = waitForStablePreview()

        let compare = waitFor("preview.compare", ofType: .button)
        compare.press(forDuration: 1.0)

        XCTAssertEqual(compare.label, "Compare", "Hold compare should release back to Compare")
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
