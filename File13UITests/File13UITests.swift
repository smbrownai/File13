//
//  File13UITests.swift
//  File13UITests
//
//  Created by Shawn Michael Brown on 5/8/26.
//

import XCTest

final class File13UITests: XCTestCase {

    override func setUpWithError() throws {
        // Stop immediately when a UI assertion fails — UI test failures cascade noisily otherwise.
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Measures how long it takes to launch the app. Useful as a regression-fence on the
        // initial-load path (auto-connect, message-cache hydration, settings store init).
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
