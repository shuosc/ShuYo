import Foundation
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testMissingFutureReservationAllowsRetryAndFallback() {
    var ledger = makeLedger(visibleFrom: now.addingTimeInterval(60))

    ledger.reconcile(enabled: true, desiredIDs: ["course"], existingIDs: [], now: now)

    XCTAssertFalse(ledger.contains("course"))
    XCTAssertTrue(ledger.storedValues.isEmpty)
  }

  func testExistingPendingReservationStillSuppressesFallback() {
    var ledger = makeLedger(visibleFrom: now.addingTimeInterval(60))

    ledger.reconcile(enabled: true, desiredIDs: ["course"], existingIDs: ["course"], now: now)

    XCTAssertTrue(ledger.contains("course"))
  }

  func testDismissedDisplayedActivityDoesNotRepeatItsReminder() {
    var ledger = makeLedger(visibleFrom: now.addingTimeInterval(-60))

    ledger.reconcile(enabled: true, desiredIDs: ["course"], existingIDs: [], now: now)

    XCTAssertTrue(ledger.contains("course"))
  }

  func testChangingLeadTimeDoesNotResurrectDismissedDisplayedActivity() {
    let ledger = makeLedger(visibleFrom: now.addingTimeInterval(-60))
    var restored = CourseActivityReservationLedger(
      stored: ledger.storedValues,
      legacyReservations: ["course": .init(visibleFrom: now.addingTimeInterval(60), expiresAt: now.addingTimeInterval(300))]
    )

    restored.reconcile(enabled: true, desiredIDs: ["course"], existingIDs: [], now: now)

    XCTAssertTrue(restored.contains("course"))
  }

  func testDisablingClearsPendingAndDismissedReservations() {
    var ledger = makeLedger(visibleFrom: now.addingTimeInterval(60))
    ledger.record("dismissed", visibleFrom: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(300))

    ledger.reconcile(enabled: false, desiredIDs: ["course", "dismissed"], existingIDs: [], now: now)

    XCTAssertTrue(ledger.storedValues.isEmpty)
    ledger.reconcile(enabled: true, desiredIDs: ["course", "dismissed"], existingIDs: [], now: now)
    XCTAssertFalse(ledger.contains("course"))
    XCTAssertFalse(ledger.contains("dismissed"))
  }

  func testRemovingCourseAndExpirationClearDismissalHistory() {
    var ledger = makeLedger(visibleFrom: now.addingTimeInterval(-60))
    ledger.record("expired", visibleFrom: now.addingTimeInterval(-60), expiresAt: now)

    ledger.reconcile(enabled: true, desiredIDs: ["expired"], existingIDs: ["course", "expired"], now: now)

    XCTAssertTrue(ledger.storedValues.isEmpty)
  }

  func testLegacyFutureReservationWithoutActivityIsNotConfirmed() {
    var ledger = CourseActivityReservationLedger(
      stored: ["course": now.addingTimeInterval(300).timeIntervalSince1970],
      legacyReservations: ["course": .init(visibleFrom: now.addingTimeInterval(60), expiresAt: now.addingTimeInterval(300))]
    )

    ledger.reconcile(enabled: true, desiredIDs: ["course"], existingIDs: [], now: now)

    XCTAssertFalse(ledger.contains("course"))
  }

  private func makeLedger(visibleFrom: Date) -> CourseActivityReservationLedger {
    var ledger = CourseActivityReservationLedger(stored: [:], legacyReservations: [:])
    ledger.record("course", visibleFrom: visibleFrom, expiresAt: now.addingTimeInterval(300))
    return ledger
  }
}
