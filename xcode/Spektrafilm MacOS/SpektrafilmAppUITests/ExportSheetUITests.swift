//
//  ExportSheetUITests.swift
//  SpektrafilmAppUITests
//
//  Covers the Export configuration sheet: format switching, per-format
//  options, cancel, and the save panel that follows Continue.
//

import XCTest

final class ExportSheetUITests: SpektrafilmAppUITestCase {

    /// The Export sheet opens, format-specific options appear for each file
    /// format, and Cancel dismisses the sheet.
    @MainActor
    func testExportSheetFormatsAndCancel() throws {
        launchApp()
        waitForRenderComplete()

        let export = waitFor("toolbar.export", ofType: .button)
        XCTAssertTrue(export.isEnabled)
        export.click()

        let sheet = waitFor("export.sheet")

        // Default format is JPEG: quality slider visible, no bit-depth picker.
        waitFor("export.jpeg.quality", ofType: .slider)
        XCTAssertFalse(element("export.bitDepth").exists)

        // Switch to TIFF: bit depth and compression options appear.
        selectMenuItem("TIFF", fromPicker: "export.format")
        waitFor("export.bitDepth")
        waitFor("export.tiff.compression", ofType: .popUpButton)

        // Switch to PNG: interlaced toggle appears (a Switch in Form context).
        selectMenuItem("PNG", fromPicker: "export.format")
        waitFor("export.png.interlaced", ofType: .switch)

        attachScreenshot(named: "Export sheet - PNG")

        // Cancel dismisses the sheet.
        element("export.cancel", ofType: .button).click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Export sheet should dismiss after Cancel")
    }

    /// Continue dismisses the sheet and presents the save panel, which can be
    /// cancelled without writing a file.
    @MainActor
    func testExportContinueShowsSavePanel() throws {
        launchApp()
        waitForRenderComplete()

        element("toolbar.export", ofType: .button).click()
        let sheet = waitFor("export.sheet")
        element("export.continue", ofType: .button).click()

        // The configuration sheet dismisses, then the NSSavePanel appears as
        // its own window (identifier 'save-panel').
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Export sheet should dismiss after Continue")

        let savePanel = app.windows["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 15), "Save panel should appear after Continue")

        // The suggested file name derives from the source name.
        XCTAssertTrue(savePanel.textFields["saveAsNameTextField"].exists)

        // Cancel it; no file is written and the app keeps running.
        savePanel.buttons["CancelButton"].click()
        XCTAssertTrue(savePanel.waitForNonExistence(timeout: 10), "Save panel should dismiss")
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
