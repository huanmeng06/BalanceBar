import XCTest
@testable import BalanceBar

final class EstimateCalibrationTriggerTests: XCTestCase {
    private final class RecordingScheduler: FetchScheduling {
        var reasons: [FetchRequestReason] = []
        func requestFetch(reason: FetchRequestReason) { reasons.append(reason) }
    }

    private let learning = 0.0
    private let qualified = 0.9
    private var scheduler: RecordingScheduler!

    override func setUp() {
        super.setUp()
        scheduler = RecordingScheduler()
    }

    private func estimate(_ percent: Double, confidence: Double) -> UsageEstimate {
        UsageEstimate(percent: percent, confidence: confidence, errorRange: 2)
    }

    private func makeTrigger(
        thresholds: @escaping (QuotaWindowKind) -> [Double] = { _ in [] }
    ) -> EstimateCalibrationTrigger {
        EstimateCalibrationTrigger(scheduler: scheduler, notificationThresholds: thresholds)
    }

    // MARK: Rise thresholds

    func testLearningPeriodRequestsAtTwoPoints() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 10)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(11.9, confidence: learning)))
        XCTAssertTrue(scheduler.reasons.isEmpty)
        XCTAssertEqual(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(12, confidence: learning)), .learningRise)
        XCTAssertEqual(scheduler.reasons, [.estimatedCalibration])
    }

    func testQualifiedEstimatorRequestsAtFivePoints() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 10)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(14.9, confidence: qualified)))
        XCTAssertTrue(scheduler.reasons.isEmpty)
        XCTAssertEqual(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(15, confidence: qualified)), .qualifiedRise)
        XCTAssertEqual(scheduler.reasons, [.estimatedCalibration])
    }

    func testConfidenceBoundaryIsQualified() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 0)
        let boundary = EstimateCalibrationConfiguration().qualifiedConfidence
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(3, confidence: boundary)))
        XCTAssertEqual(
            trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(3, confidence: boundary - 0.01)),
            .learningRise)
    }

    func testNoAnchorNoDropAndInvalidEstimatesNeverRequest() {
        let trigger = makeTrigger()
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(50, confidence: learning)))
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 40)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(30, confidence: learning)))
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(.nan, confidence: learning)))
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(60, confidence: .nan)))
        XCTAssertTrue(scheduler.reasons.isEmpty)
    }

    // MARK: Self rate limiting

    func testSecondRequestNeedsAnotherFullStep() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 10)
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(12, confidence: learning)))
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(13.9, confidence: learning)))
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(14, confidence: learning)))
        XCTAssertEqual(scheduler.reasons.count, 2)
    }

    func testOfficialReadingReanchorsAndRearms() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 10)
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(12, confidence: learning)))
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 12)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(13, confidence: learning)))
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(14, confidence: learning)))
    }

    func testResetToLowerOfficialValueReanchors() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 80)
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 1)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(2, confidence: learning)))
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(3, confidence: learning)))
    }

    func testAccountsAndWindowsAreIndependent() {
        let trigger = makeTrigger()
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 10)
        trigger.recordOfficial(accountID: "B", window: .fiveHour, percent: 10)
        trigger.recordOfficial(accountID: "A", window: .sevenDay, percent: 10)
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(12, confidence: learning)))
        XCTAssertNotNil(trigger.evaluate(accountID: "B", window: .fiveHour, estimate: estimate(12, confidence: learning)))
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .sevenDay, estimate: estimate(12, confidence: learning)))
        XCTAssertEqual(scheduler.reasons.count, 3)
    }

    // MARK: Notification threshold

    func testApproachingNotificationThresholdRequestsBeforeRiseStep() {
        // Remaining thresholds 20 and 10; qualified step is 5 points.
        let trigger = makeTrigger { _ in [20, 10] }
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 78)
        // Anchor remaining 22 is already within the 2-point margin of 20, so a 1-point rise is required.
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(78.5, confidence: qualified)))
        XCTAssertEqual(
            trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(79, confidence: qualified)),
            .notificationThreshold(20))
        XCTAssertEqual(scheduler.reasons, [.estimatedCalibration])
    }

    func testNotificationTriggerNeedsMinimumRiseWhenAnchorAlreadyNearThreshold() {
        let trigger = makeTrigger { _ in [10] }
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 89) // remaining 11, within margin already
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(89.5, confidence: qualified)))
        XCTAssertEqual(
            trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(90, confidence: qualified)),
            .notificationThreshold(10))
    }

    func testThresholdAlreadyCrossedByOfficialValueDoesNotTrigger() {
        let trigger = makeTrigger { _ in [10] }
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 92) // remaining 8, already crossed
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(94, confidence: qualified)))
        XCTAssertTrue(scheduler.reasons.isEmpty)
    }

    func testFarFromThresholdDoesNotTrigger() {
        let trigger = makeTrigger { _ in [10] }
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 20)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(24, confidence: qualified)))
        XCTAssertTrue(scheduler.reasons.isEmpty)
    }

    func testThresholdsAreAskedPerWindow() {
        let trigger = makeTrigger { $0 == .sevenDay ? [10] : [] }
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 87)
        trigger.recordOfficial(accountID: "A", window: .sevenDay, percent: 87)
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(89, confidence: qualified)))
        XCTAssertEqual(
            trigger.evaluate(accountID: "A", window: .sevenDay, estimate: estimate(89, confidence: qualified)),
            .notificationThreshold(10))
    }

    func testNotificationRequestDoesNotRepeatWithoutFurtherRise() {
        let trigger = makeTrigger { _ in [10] }
        trigger.recordOfficial(accountID: "A", window: .fiveHour, percent: 86)
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(88, confidence: qualified)))
        XCTAssertNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(88.5, confidence: qualified)))
        XCTAssertNotNil(trigger.evaluate(accountID: "A", window: .fiveHour, estimate: estimate(89, confidence: qualified)))
    }
}
