//
//  UITestSupport.swift
//  SpektrafilmAppUITests
//
//  Shared base class and helpers for the SpektrafilmApp end-to-end UI tests.
//

import AppKit
import ImageIO
import XCTest

/// Base class for all SpektrafilmApp E2E UI tests.
///
/// Every test launches the app with `SPEKTRAFILM_UI_TEST=1`, which makes the
/// app synthesize and load a deterministic test image at startup (see
/// `UITestSupport.swift` in the app target). This drives the app into the
/// post-"Open Image" state without automating `NSOpenPanel`, which is
/// impractical to drive reliably (and impossible under the app sandbox).
///
/// Accessibility notes (verified against the running app):
/// - SwiftUI elements carrying an `accessibilityIdentifier` expose their text
///   in `value`, not `label` (status bar, zoom label, slider value texts).
/// - Inspector panel headers are `DisclosureTriangle` elements whose `label`
///   is the panel title and whose `value` is 0 (collapsed) / 1 (expanded).
class SpektrafilmAppUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Launch

    /// Launches the app with the synthetic-image test hook enabled.
    /// - Parameters:
    ///   - livePreview: mirrors the "Live preview" setting; when false the
    ///     toolbar Render button is shown and no automatic render occurs.
    ///   - interfaceMode: value for the `adjustmentInterfaceMode` default
    ///     ("quick", "basic", "advanced", "debug").
    @MainActor
    @discardableResult
    func launchApp(livePreview: Bool = true, interfaceMode: String = "basic", compareMode: String = "click") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SPEKTRAFILM_UI_TEST"] = "1"
        app.launchEnvironment["SPEKTRAFILM_UI_TEST_LIVE_PREVIEW"] = livePreview ? "1" : "0"
        app.launchArguments += [
            "-adjustmentInterfaceMode", interfaceMode,
            "-adjustmentInspectorSoloPanels", "YES",
            "-appAppearance", "light",
            "-previewCompareMode", compareMode,
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        self.app = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "Main window should appear")
        return app
    }

    /// Launches the app without the test hook: no image is loaded, so the
    /// empty state is shown.
    @MainActor
    @discardableResult
    func launchAppWithoutImage() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-adjustmentInterfaceMode", "basic",
            "-appAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        self.app = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "Main window should appear")
        return app
    }

    // MARK: - Element lookup

    func element(_ identifier: String, ofType type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type)[identifier]
    }

    @discardableResult
    func waitFor(_ identifier: String, ofType type: XCUIElement.ElementType = .any, timeout: TimeInterval = 10) -> XCUIElement {
        let e = element(identifier, ofType: type)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "Expected element '\(identifier)' to exist")
        return e
    }

    // MARK: - Status / render waiting

    var statusText: XCUIElement { app.staticTexts["status.text"] }

    /// The current status bar string (exposed via `value`, not `label`).
    var statusValue: String { statusText.value as? String ?? "" }

    /// Waits until the status bar shows a completed render ("Rendered · auto
    /// exposure …") or a failure. Returns the final status string.
    @discardableResult
    func waitForRenderComplete(timeout: TimeInterval = 120) -> String {
        let predicate = NSPredicate(format: "value CONTAINS 'Rendered' OR value CONTAINS 'failed' OR value CONTAINS 'cancelled'")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: statusText)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Render should complete; last status: '\(statusValue)'")
        return statusValue
    }

    /// Waits until a render actually starts ("Rendering…"). Use before
    /// `waitForRenderComplete` when the previous status may already be
    /// "Rendered" from an earlier render.
    func waitForRenderStart(timeout: TimeInterval = 20) {
        let predicate = NSPredicate(format: "value BEGINSWITH 'Rendering'")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: statusText)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Render should start; last status: '\(statusValue)'")
    }

    /// Waits until the synthetic image is loaded, signalled by the preview
    /// zoom controls becoming visible (they only appear with an image).
    func waitForImageLoaded(timeout: TimeInterval = 30) {
        XCTAssertTrue(element("preview.fit", ofType: .button).waitForExistence(timeout: timeout),
                      "Synthetic test image should load (zoom controls visible)")
    }

    // MARK: - Inspector panels

    /// Expands an accordion panel by clicking its disclosure triangle, unless
    /// it is already expanded.
    func expandPanel(titled title: String, revealing identifier: String? = nil) {
        let disclosure = app.disclosureTriangles[title].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10), "Panel disclosure '\(title)' should exist")
        let expanded = (disclosure.value as? Int) == 1 || (disclosure.value as? Bool) == true
        if !expanded {
            disclosure.click()
        }
        if let identifier {
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 10),
                          "Panel '\(title)' should reveal '\(identifier)'")
        }
    }

    /// Collapses an expanded accordion panel.
    func collapsePanel(titled title: String) {
        let disclosure = app.disclosureTriangles[title].firstMatch
        guard disclosure.waitForExistence(timeout: 10) else { return }
        let expanded = (disclosure.value as? Int) == 1 || (disclosure.value as? Bool) == true
        if expanded {
            disclosure.click()
        }
    }

    // MARK: - Profile tiles

    /// All film profile tiles, in display order.
    var filmTiles: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'profile.film.'"))
    }

    /// All print profile tiles, in display order (excluding the "(none)" tile).
    var printTiles: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'profile.print.' AND identifier != 'profile.print.none'"))
    }

    // MARK: - Controls

    /// Moves a slider off its current value by clicking a point on its track
    /// (macOS sliders jump to the clicked position), then nudges with the
    /// keyboard for good measure.
    func nudgeSlider(_ identifier: String) {
        let slider = waitFor(identifier, ofType: .slider)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
    }

    /// The text of a `ParameterSlider`'s value label (exposed via `value`).
    func sliderValueText(_ identifier: String) -> String? {
        app.staticTexts["\(identifier).value"].value as? String
    }

    /// Opens a `.menu`-style picker (NSPopUpButton) and chooses an item.
    func selectMenuItem(_ item: String, fromPicker identifier: String, in container: XCUIElement? = nil) {
        let scope: XCUIElement = container ?? app
        let popUp = scope.popUpButtons[identifier].firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 10), "Picker '\(identifier)' should exist")
        popUp.click()
        let menuItem = app.menuItems[item].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10), "Menu item '\(item)' should exist")
        menuItem.click()
    }

    // MARK: - Screenshots

    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Preview pixel comparison

    /// A normalized RGBA8 snapshot of the photo preview element.
    struct PreviewPixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    /// Captures the `preview.image` element, downscales it to a fixed width, and
    /// returns RGBA8 pixels. Fixed width keeps comparisons stable across window
    /// and backing-scale differences.
    @MainActor
    func previewPixels(targetWidth: Int = 480) -> PreviewPixels? {
        let preview = element("preview.image", ofType: .image)
        guard preview.exists else { return nil }
        let png = preview.screenshot().pngRepresentation
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let w = min(targetWidth, cg.width)
        let h = max(1, Int((CGFloat(cg.height) * CGFloat(w) / CGFloat(cg.width)).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return PreviewPixels(width: w, height: h, rgba: bytes)
    }

    /// Fraction of pixels whose max channel delta exceeds `channelThreshold`,
    /// optionally restricted to a normalized horizontal range.
    func fractionDifferent(
        _ a: PreviewPixels,
        _ b: PreviewPixels,
        channelThreshold: Int = 12,
        xRange: ClosedRange<Double> = 0...1
    ) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let minX = max(0, Int(Double(a.width) * xRange.lowerBound))
        let maxX = min(a.width, Int(Double(a.width) * xRange.upperBound))
        guard maxX > minX else { return 0 }
        var differing = 0
        var total = 0
        for y in 0..<a.height {
            for x in minX..<maxX {
                let o = (y * a.width + x) * 4
                let d = max(abs(Int(a.rgba[o]) - Int(b.rgba[o])),
                            max(abs(Int(a.rgba[o + 1]) - Int(b.rgba[o + 1])),
                                abs(Int(a.rgba[o + 2]) - Int(b.rgba[o + 2]))))
                total += 1
                if d > channelThreshold { differing += 1 }
            }
        }
        return total > 0 ? Double(differing) / Double(total) : 0
    }

    /// Polls the preview until two consecutive captures are effectively
    /// identical, so ROI refinement and compare tile swaps have settled.
    @MainActor
    func waitForStablePreview(timeout: TimeInterval = 20, targetWidth: Int = 480) -> PreviewPixels? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = previewPixels(targetWidth: targetWidth)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.35)
            guard let current = previewPixels(targetWidth: targetWidth) else { continue }
            if let previous = last, previous.width == current.width, previous.height == current.height,
               fractionDifferent(previous, current, channelThreshold: 6) < 0.002 {
                return current
            }
            last = current
        }
        return last
    }
}
