import Foundation
import XCTest
@testable import Runner

#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import AlarmKit
import Flutter
import UIKit

/// Opt-in checks against the installed app's real system reservations.
@available(iOS 26.0, *)
@MainActor
class DeviceRemindersVerificationTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["SHUYO_VERIFY_DEVICE_REMINDERS"] == "1",
      "Requires an explicitly selected physical-device verification run."
    )
    #if targetEnvironment(simulator)
      throw XCTSkip("Alarm delivery must be verified on a physical iPhone.")
    #endif
  }

  func test02AlarmSurvivesLastThirtySecondsSyncAndAlerts() async throws {
    let manager = AlarmManager.shared
    XCTAssertEqual(manager.authorizationState, .authorized)
    let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
    let defaults = UserDefaults.standard
    // Let the normal Flutter startup sync finish before taking the system snapshot.
    for _ in 0..<30 {
      if defaults.dictionary(forKey: "early_class_alarm_titles")?.isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(500))
    }
    let ownedIDs = Set(defaults.stringArray(forKey: "early_class_alarm_ids") ?? [])
    let titles = try XCTUnwrap(defaults.dictionary(forKey: "early_class_alarm_titles") as? [String: String])
    let originalAlarms = try manager.alarms.filter { ownedIDs.contains($0.id.uuidString) }
    let originalIDs = Set(originalAlarms.map(\.id))
    var originalRequests: [[String: Any]] = []
    for alarm in originalAlarms {
      if case let .fixed(date)? = alarm.schedule, date > Date() {
        originalRequests.append([
          "fireTime": Int64(date.timeIntervalSince1970 * 1000),
          "title": try XCTUnwrap(titles[alarm.id.uuidString])
        ])
      }
    }
    XCTAssertFalse(originalRequests.isEmpty, "Requires the user's existing early-class reservations.")
    let fireMilliseconds = Int64(Date().addingTimeInterval(70).timeIntervalSince1970 * 1000)
    let fireDate = Date(timeIntervalSince1970: Double(fireMilliseconds) / 1000)
    addTeardownBlock { @MainActor in
      for alarm in try manager.alarms where alarm.schedule == .fixed(fireDate) {
        try manager.cancel(id: alarm.id)
      }
      _ = try await self.sync(originalRequests, delegate: delegate)
      XCTAssertEqual(Set(try manager.alarms.map(\.id)), originalIDs)
    }

    let requests = originalRequests + [[
      "fireTime": fireMilliseconds,
      "title": "ShuYo 闹钟验证"
    ]]
    _ = try await sync(requests, delegate: delegate)
    let addedIDs = Set(try manager.alarms.map(\.id)).subtracting(originalIDs)
    XCTAssertEqual(addedIDs.count, 1)
    let verificationID = try XCTUnwrap(addedIDs.first)
    print("SHUYO_DEVICE_ALARM_SCHEDULED \(fireDate)")

    try await Task.sleep(for: .seconds(45))
    _ = try await sync(requests, delegate: delegate)
    XCTAssertEqual(Set(try manager.alarms.map(\.id)), originalIDs.union([verificationID]))

    var alerted = false
    while Date() < fireDate.addingTimeInterval(15) {
      if try manager.alarms.first(where: { $0.id == verificationID })?.state == .alerting {
        alerted = true
        print("SHUYO_DEVICE_ALARM_ALERTING \(verificationID)")
        break
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    XCTAssertTrue(alerted, "The system must enter the actual alarm alerting state.")
    // Keep the system alert visible long enough to capture it from the host.
    try await Task.sleep(for: .seconds(8))
    if alerted { try manager.stop(id: verificationID) }
  }

  func test01LiveActivityRendersActualUpcomingCourse() async throws {
    XCTAssertTrue(ActivityAuthorizationInfo().areActivitiesEnabled)
    let original = try XCTUnwrap(
      Activity<CourseActivityAttributes>.activities
        .filter { $0.activityState == .pending && $0.content.state.visibleFrom > Date() }
        .min { $0.content.state.startsAt < $1.content.state.startsAt }
    )
    let attributes = original.attributes
    let content = original.content
    let verificationOccurrence = "shuyo-device-verification-\(UUID().uuidString)"
    addTeardownBlock { @MainActor in
      for activity in Activity<CourseActivityAttributes>.activities
        where activity.attributes.occurrenceID == verificationOccurrence {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      if let restored = Activity<CourseActivityAttributes>.activities.first(where: {
        $0.attributes.occurrenceID == attributes.occurrenceID && $0.activityState == .pending
      }) {
        XCTAssertEqual(restored.content.state, content.state)
        return
      }
      let restored = try Activity.request(
        attributes: attributes, content: content, pushType: nil, style: .standard,
        alertConfiguration: AlertConfiguration(
          title: LocalizedStringResource(stringLiteral: content.state.courseName),
          body: LocalizedStringResource(stringLiteral: "即将上课 · \(content.state.location)"),
          sound: .default
        ),
        start: content.state.visibleFrom
      )
      XCTAssertEqual(restored.activityState, .pending)
    }
    // Free one reservation slot, then restore the exact original course in teardown.
    await original.end(nil, dismissalPolicy: .immediate)
    try await Task.sleep(for: .seconds(1))
    let preview = try Activity.request(
      attributes: CourseActivityAttributes(occurrenceID: verificationOccurrence),
      content: content, pushType: nil
    )
    XCTAssertEqual(preview.activityState, .active)
    print("SHUYO_DEVICE_LIVE_ACTIVITY_VISIBLE \(preview.id)")
    try await Task.sleep(for: .seconds(30))
  }

  private func sync(_ requests: [[String: Any]], delegate: AppDelegate) async throws -> Int {
    var response: Any?
    await delegate.syncEarlyClassAlarms(requests, enabled: true) { response = $0 }
    if let error = response as? FlutterError {
      throw NSError(
        domain: error.code, code: 1,
        userInfo: [NSLocalizedDescriptionKey: error.message ?? error.code]
      )
    }
    return try XCTUnwrap(response as? Int)
  }
}
#endif

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
