import XCTest

final class SplitInboxUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["mail-demo-0"].waitForExistence(timeout: 8))
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    func testSplitAndExpandedReader() {
        XCTAssertEqual(app.staticTexts["readerSubject"].label, "The next chapter for Northwind")
        capture("01-split-inbox")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(app.buttons["readerExpand"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["readerExpand"].label, "Collapse reader")
        capture("02-expanded-reader")
        app.buttons["readerExpand"].tap()
        XCTAssertEqual(app.buttons["readerExpand"].label, "Expand reader")
        app.buttons["inboxMenu"].tap()
        XCTAssertTrue(app.buttons["filter-Read"].waitForExistence(timeout: 3))
    }
    func testTickerScrollSelectsTopMessageWithoutMarkingRead() {
        let ticker = app.scrollViews["inboxTicker"]
        ticker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 0.1, thenDragTo: ticker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let changed = NSPredicate(format: "label != %@", "The next chapter for Northwind")
        expectation(for: changed, evaluatedWith: app.staticTexts["readerSubject"])
        waitForExpectations(timeout: 4)
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mail-' AND value == 'Selected'")).firstMatch
        XCTAssertTrue(selected.exists)
        XCTAssertTrue(selected.label.contains(app.staticTexts["readerSubject"].label))
        capture("03-ticker-selection")
        app.buttons["inboxMenu"].tap()
        app.buttons["filter-Read"].tap()
        XCTAssertTrue(app.staticTexts["A little breathing room."].exists)
    }
    func testLongPressPreviewDoesNotChangeSelectionOrReadStatus() {
        app.buttons["mail-demo-1"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["previewSelect"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["A few thoughts on the new inbox"].exists)
        capture("04-long-press-preview")
        app.buttons["Close preview"].tap()
        XCTAssertEqual(app.staticTexts["readerSubject"].label, "The next chapter for Northwind")
        app.buttons["inboxMenu"].tap()
        app.buttons["filter-Read"].tap()
        XCTAssertTrue(app.staticTexts["A little breathing room."].exists)
    }
    func testSwipeReadMovesMessageToReadAndAdvances() {
        app.buttons["mail-demo-0"].swipeLeft()
        let disappeared = NSPredicate(format: "exists == false")
        expectation(for: disappeared, evaluatedWith: app.buttons["mail-demo-0"])
        waitForExpectations(timeout: 4)
        XCTAssertEqual(app.staticTexts["readerSubject"].label, "A few thoughts on the new inbox")
        app.buttons["inboxMenu"].tap()
        capture("05-inbox-menu")
        app.buttons["filter-Read"].tap()
        XCTAssertTrue(app.buttons["mail-demo-0"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["readerSubject"].label, "The next chapter for Northwind")
        capture("06-read-section")
    }
    func testReadAndStarButtonsAndReplyDraft() {
        app.buttons["readerStar"].tap()
        XCTAssertTrue(app.buttons["readerStar"].label.contains("Starred"))
        app.buttons["readerReply"].tap()
        XCTAssertTrue(app.navigationBars["Reply"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        app.buttons["readerRead"].tap()
        XCTAssertEqual(app.staticTexts["readerSubject"].label, "A few thoughts on the new inbox")
    }
}
