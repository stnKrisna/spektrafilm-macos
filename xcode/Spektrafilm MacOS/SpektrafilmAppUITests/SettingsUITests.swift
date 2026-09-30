//
//  SettingsUITests.swift
//  SpektrafilmAppUITests
//
//  Covers the Settings scene and interface-mode-driven layout changes.
//
//  Note: `.menu`-style pickers inside the Settings scene window do not respond
//  to synthesized selection in this environment (verified: the menu opens and
//  items are listed, but clicks/keys never commit a selection — while the same
//  interactions work in modal sheets). Interface-mode-driven layout is therefore
//  exercised via the `adjustmentInterfaceMode` launch default, which flows
//  through the same SwiftUI rebuilding path.
//

import XCTest

final class SettingsUITests: SpektrafilmAppUITestCase {

    // MARK: - Helpers

    private var settingsWindow: XCUIElement {
        app.windows["com_apple_SwiftUI_Settings_window"]
    }

    /// Opens the Settings window with Cmd+, and selects the Interface tab.
    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window should open")
        clickSettingsTab("Interface")
        XCTAssertTrue(app.popUpButtons["settings.interface.layout"].waitForExistence(timeout: 10),
                      "Interface layout picker should exist")
    }

    private func closeSettings() {
        guard settingsWindow.exists else { return }
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    }

    /// Clicks a tab in the Settings TabView (Interface / Preview / Advance).
    private func clickSettingsTab(_ title: String) {
        let tab = settingsWindow.buttons[title].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Settings tab '\(title)' should exist")
        tab.click()
    }

    /// Opens a settings picker and asserts it lists the expected items, then
    /// dismisses the menu without changing the selection.
    private func assertPickerListsItems(_ items: [String], picker identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let popUp = app.popUpButtons[identifier].firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 10), "Picker '\(identifier)' should exist", file: file, line: line)
        popUp.click()
        for item in items {
            XCTAssertTrue(app.menuItems[item].firstMatch.waitForExistence(timeout: 5),
                          "Picker '\(identifier)' should list '\(item)'", file: file, line: line)
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    // MARK: - Tests

    /// Launching with the Advanced interface shows the advanced panel set.
    @MainActor
    func testAdvancedInterfaceModeShowsAdvancedPanels() throws {
        launchApp(interfaceMode: "advanced")
        waitForImageLoaded()

        // The large profiles panel is expanded by default; collapse it so the
        // remaining (lazily realized) headers appear.
        collapsePanel(titled: "Film & Print Profiles")

        waitFor("panel.source")
        waitFor("panel.film-development")
        waitFor("panel.texture")
        waitFor("panel.print-controls")
        waitFor("panel.scan-output")
        waitFor("panel.engine")

        // Basic-only panels are absent.
        XCTAssertFalse(element("panel.light").exists)
        XCTAssertFalse(element("panel.character").exists)

        attachScreenshot(named: "Advanced interface")
    }

    /// The Settings window opens and its pickers list the expected options.
    @MainActor
    func testSettingsWindowAndPickers() throws {
        launchApp()
        waitForImageLoaded()

        openSettings()

        // Layout picker lists the non-debug modes.
        assertPickerListsItems(["Quick", "Basic", "Advanced"], picker: "settings.interface.layout")

        // Appearance and preview-background pickers.
        assertPickerListsItems(["System", "Light", "Dark"], picker: "settings.appearance")
        assertPickerListsItems(["Mid-gray", "Black", "White"], picker: "settings.preview.background")

        // Compare picker on the Preview tab.
        clickSettingsTab("Preview")
        assertPickerListsItems(["Click to compare", "Hold to compare", "Before/after slider"],
                               picker: "settings.compare")

        closeSettings()
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    /// Turning off Live preview reveals the toolbar Render button.
    @MainActor
    func testLivePreviewToggleRevealsRenderButton() throws {
        launchApp()
        waitForRenderComplete()

        // Live preview on: no Render button.
        XCTAssertFalse(element("toolbar.render", ofType: .button).exists)

        openSettings()
        clickSettingsTab("Preview")

        // Form toggles are Switch elements on macOS.
        let livePreview = waitFor("settings.livePreview", ofType: .switch)
        XCTAssertEqual(livePreview.value as? Int, 1)
        livePreview.click()
        XCTAssertEqual(livePreview.value as? Int, 0, "Live preview switch should turn off")

        closeSettings()

        // Render button now visible; clicking it renders.
        let render = waitFor("toolbar.render", ofType: .button)
        XCTAssertTrue(render.isEnabled)
        render.click()
        waitForRenderStart()
        waitForRenderComplete()
    }
}
