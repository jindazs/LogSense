//
//  CTDUITests.swift
//  CTDUITests
//
//  Created by Yuki Jin on 2024/08/25.
//

import XCTest

final class CTDUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testPrimaryNavigationIsDiscoverable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Today"].exists)
        XCTAssertTrue(app.buttons["ToDo"].exists)
        XCTAssertTrue(app.buttons["Photos"].exists)
        XCTAssertTrue(app.buttons["その他の操作"].exists)

        app.buttons["その他の操作"].tap()
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 3))
        app.buttons["その他の操作"].tap()
        XCTAssertFalse(app.buttons["設定"].waitForExistence(timeout: 1))

        app.buttons["Today"].tap()
        app.buttons["その他の操作"].tap()
        XCTAssertTrue(app.buttons["今日に戻る"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["今年のページを開く"].exists)
        app.buttons["今日に戻る"].tap()

        app.buttons["Photos"].tap()
        app.buttons["その他の操作"].tap()
        let photoQueueButton = app.buttons["写真アップロードキュー"]
        XCTAssertTrue(photoQueueButton.waitForExistence(timeout: 3))
        XCTAssertLessThan(
            photoQueueButton.frame.maxY,
            app.buttons["その他の操作"].frame.minY,
            "補助メニューは下部ナビゲーションの上に表示される必要があります"
        )
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
