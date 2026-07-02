import XCTest
@testable import CodexSwitchboard

final class ResetTextScaleTests: XCTestCase {
    func testResetTextScaleClampsToReadableRange() {
        XCTAssertEqual(ResetTextScale.clampedPercent(40), 80)
        XCTAssertEqual(ResetTextScale.clampedPercent(135), 135)
        XCTAssertEqual(ResetTextScale.clampedPercent(260), 200)
    }

    func testPresetLookupUsesNearestNamedSize() {
        XCTAssertEqual(ResetTextScale.nearestPresetPercent(to: 101), 100)
        XCTAssertEqual(ResetTextScale.nearestPresetPercent(to: 128), 125)
        XCTAssertEqual(ResetTextScale.nearestPresetPercent(to: 149), 150)
    }

    func testCompleteLayoutReservesMoreSpaceForLargeResetText() {
        let small = CompactRowLayout.metrics(
            totalWidth: 760,
            showsFullInformation: true,
            showsActionControl: true,
            resetTextScale: 1
        )
        let large = CompactRowLayout.metrics(
            totalWidth: 760,
            showsFullInformation: true,
            showsActionControl: true,
            resetTextScale: 1.5
        )

        XCTAssertGreaterThan(large.sessionResetWidth, small.sessionResetWidth)
        XCTAssertGreaterThan(large.weeklyResetWidth, small.weeklyResetWidth)
        XCTAssertGreaterThan(large.planCycleWidth, small.planCycleWidth)
    }

    func testCompleteLayoutFitsLargestScaleInsideFixedPopover() {
        let layout = CompactRowLayout.metrics(
            totalWidth: 760,
            showsFullInformation: true,
            showsActionControl: true,
            resetTextScale: 2
        )
        let contentWidth = 760 - CompactRowLayout.horizontalPadding * 2
        let fixedWidth = 16
            + layout.workspaceWidth
            + layout.actionWidth
            + layout.metricWidth * 2
            + layout.sessionResetWidth
            + layout.weeklyResetWidth
            + layout.planCycleWidth
            + layout.spacing * 6

        XCTAssertLessThanOrEqual(layout.emailWidth + fixedWidth, contentWidth)
    }

    func testFocusedLayoutReservesScaledFreeResetStatusWidth() {
        let layout = CompactRowLayout.metrics(
            totalWidth: 580,
            showsFullInformation: false,
            showsActionControl: false,
            resetTextScale: 1.25
        )
        let contentWidth = 580 - CompactRowLayout.horizontalPadding * 2
        let freeResetWidth = ceil((layout.metricWidth * 2 + layout.spacing) * 1.25)
        let fixedWidth = 16 + layout.actionWidth + freeResetWidth + layout.spacing * 3

        XCTAssertLessThanOrEqual(layout.emailWidth + fixedWidth, contentWidth)
    }
}
