//
//  AdjustmentsAndRenderUITests.swift
//  SpektrafilmAppUITests
//
//  Covers parameter sliders, toggles, reset-to-default, and the explicit
//  Render button used when live preview is disabled.
//

import XCTest

final class AdjustmentsAndRenderUITests: SpektrafilmAppUITestCase {

    /// Moving the "Exposure compensation" slider updates its value text and
    /// enables its reset button; resetting restores the default.
    @MainActor
    func testExposureSliderUpdatesValueAndReset() throws {
        launchApp()
        waitForRenderComplete()

        expandPanel(titled: "Light & Color", revealing: "slider.exposure-compensation")

        let reset = element("slider.exposure-compensation.reset", ofType: .button)
        XCTAssertEqual(sliderValueText("slider.exposure-compensation"), "0 EV")
        XCTAssertFalse(reset.isEnabled, "Reset should be disabled at the default value")

        nudgeSlider("slider.exposure-compensation")

        XCTAssertNotEqual(sliderValueText("slider.exposure-compensation"), "0 EV",
                          "Slider value text should change after nudging")
        XCTAssertTrue(reset.isEnabled, "Reset should become enabled once the value differs from default")

        // Live preview: the parameter change re-renders after the debounce.
        waitForRenderStart(timeout: 30)
        waitForRenderComplete()

        reset.click()
        XCTAssertEqual(sliderValueText("slider.exposure-compensation"), "0 EV",
                       "Reset should restore the default value")
    }

    /// Toggling "Scan film directly" flips the checkbox state.
    @MainActor
    func testScanFilmDirectlyToggle() throws {
        launchApp()
        waitForRenderComplete()

        expandPanel(titled: "Output", revealing: "toggle.scan-film-directly")

        let toggle = waitFor("toggle.scan-film-directly", ofType: .checkBox)
        let initial = toggle.value as? Bool
        XCTAssertNotNil(initial)

        toggle.click()
        XCTAssertEqual(toggle.value as? Bool, !(initial ?? false), "Toggle state should flip")

        // I/O change re-renders (debounced).
        waitForRenderStart(timeout: 30)
        waitForRenderComplete()
    }

    /// With live preview disabled, no automatic render happens on load and the
    /// toolbar Render button drives the preview.
    @MainActor
    func testRenderButtonWhenLivePreviewDisabled() throws {
        launchApp(livePreview: false)
        waitForImageLoaded()

        // No automatic render: status stays at the loaded message and the
        // Render button is visible and enabled.
        XCTAssertTrue(statusValue.contains("Loaded spektrafilm-uitest"),
                      "Unexpected status: '\(statusValue)'")
        let render = waitFor("toolbar.render", ofType: .button)
        XCTAssertTrue(render.isEnabled)

        render.click()
        waitForRenderStart()
        waitForRenderComplete()

        XCTAssertTrue(element("toolbar.export", ofType: .button).isEnabled)
        attachScreenshot(named: "Manual render complete")
    }
}
