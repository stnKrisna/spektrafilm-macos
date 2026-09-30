//
//  ImageAndProfilesUITests.swift
//  SpektrafilmAppUITests
//
//  Covers loading an image (via the test hook), the profile browsers
//  populating, and film/print profile selection.
//

import XCTest

final class ImageAndProfilesUITests: SpektrafilmAppUITestCase {

    /// The synthetic image loads, the preview appears, the status updates, and
    /// the film/print profile grids populate with tiles.
    @MainActor
    func testImageLoadsAndProfileGridsPopulate() throws {
        launchApp()
        waitForImageLoaded()

        // Zoom and compare controls appear once an image is loaded.
        waitFor("preview.fit", ofType: .button)
        waitFor("preview.compare", ofType: .button)

        // Profile grids populate from the bundled data pack.
        XCTAssertTrue(filmTiles.count > 1, "Film grid should list bundled film profiles")
        expandPanel(titled: "Print", revealing: "profiles.print.browser")
        XCTAssertTrue(printTiles.count > 0, "Print grid should list bundled print profiles")
        XCTAssertTrue(element("profile.print.none", ofType: .button).exists, "Print grid should include the '(none)' tile")

        // The first render completes and Export becomes available.
        waitForRenderComplete()
        XCTAssertTrue(element("toolbar.export", ofType: .button).isEnabled)

        attachScreenshot(named: "Image loaded with profiles")
    }

    /// Selecting a different film profile triggers a re-render.
    @MainActor
    func testSelectingFilmProfileRerenders() throws {
        launchApp()
        waitForRenderComplete()

        // The first film is auto-selected; pick a different one.
        let tiles = filmTiles
        XCTAssertTrue(tiles.count > 1)
        let target = tiles.element(boundBy: 1)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()

        // Selection change triggers a live render.
        waitForRenderStart()
        waitForRenderComplete()
    }

    /// Selecting "(none)" for the print (scan film directly) and then a paper
    /// profile again both trigger re-renders.
    @MainActor
    func testSelectingPrintProfileAndNone() throws {
        launchApp()
        waitForRenderComplete()

        expandPanel(titled: "Print", revealing: "profiles.print.browser")

        // Choose "(none)" — scan film directly.
        let noneTile = waitFor("profile.print.none", ofType: .button)
        noneTile.click()
        waitForRenderStart()
        waitForRenderComplete()

        // Choose a paper profile again.
        let papers = printTiles
        XCTAssertTrue(papers.count > 0)
        let paper = papers.element(boundBy: 0)
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        paper.click()
        waitForRenderStart()
        waitForRenderComplete()
    }
}
