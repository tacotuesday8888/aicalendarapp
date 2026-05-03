//
//  IOSAppUITests.swift
//  iOSAppUITests
//
//  Created by Langqi Zhao on 4/12/26.
//

import XCTest

final class IOSAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAuthScreenAppearsOnFirstLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Student planner, not another empty shell."].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
