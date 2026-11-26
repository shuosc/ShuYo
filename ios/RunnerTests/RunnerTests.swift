import CoreLocation
import Flutter
import Foundation
import UIKit
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

private final class FakeCampusMapLocationManager: CampusMapLocationManaging {
  weak var locationDelegate: CampusMapLocationManagerDelegate?
  var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
  var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
  var activityType: CLActivityType = .other
  var pausesLocationUpdatesAutomatically = false
  var authorizationStatus: CLAuthorizationStatus
  var location: CLLocation?

  var requestWhenInUseCount = 0
  var requestLocationCount = 0
  var startUpdatingCount = 0
  var stopUpdatingCount = 0

  init(authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse) {
    self.authorizationStatus = authorizationStatus
  }

  func requestWhenInUseAuthorization() {
    requestWhenInUseCount += 1
  }

  func requestLocation() {
    requestLocationCount += 1
  }

  func startUpdatingLocation() {
    startUpdatingCount += 1
  }

  func stopUpdatingLocation() {
    stopUpdatingCount += 1
  }

  func simulateAuthorizationChange(_ status: CLAuthorizationStatus) {
    authorizationStatus = status
    locationDelegate?.locationManagerDidChangeAuthorization(self)
  }

  func simulateLocations(_ locations: [CLLocation]) {
    location = locations.last
    locationDelegate?.locationManager(self, didUpdateLocations: locations)
  }

  func simulateError(_ error: Error) {
    locationDelegate?.locationManager(self, didFailWithError: error)
  }
}

final class CampusMapLocationControllerTests: XCTestCase {
  private func makeLocation(
    latitude: Double = 31.3162,
    longitude: Double = 121.3915,
    accuracy: CLLocationAccuracy = 10,
    ageSeconds: TimeInterval = 0
  ) -> CLLocation {
    CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      altitude: 0,
      horizontalAccuracy: accuracy,
      verticalAccuracy: 0,
      timestamp: Date().addingTimeInterval(-ageSeconds)
    )
  }

  func testAuthorizationInterruptedByBackgroundDoesNotDeadlockNextLocate() {
    let center = NotificationCenter()
    let single = FakeCampusMapLocationManager(authorizationStatus: .notDetermined)
    let controller = CampusMapLocationController(
      makeManager: { single },
      checkServicesEnabled: { $0(true) },
      isAppActive: { true },
      locateTimeoutSeconds: 5,
      activeRecheckDelaySeconds: 0,
      notificationCenter: center
    )

    var firstResponse: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { firstResponse = $0 }
    XCTAssertEqual(single.requestWhenInUseCount, 1)
    XCTAssertNil(firstResponse)

    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertEqual((firstResponse as? FlutterError)?.code, "location_unavailable")

    var secondResponse: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { secondResponse = $0 }
    XCTAssertEqual(single.requestWhenInUseCount, 2)
    XCTAssertNil(secondResponse)

    single.simulateAuthorizationChange(.authorizedWhenInUse)
    XCTAssertEqual(single.requestLocationCount, 1)
    single.simulateLocations([makeLocation()])

    let payload = secondResponse as? [String: Double]
    XCTAssertEqual(payload?["latitude"], 31.3162)
    XCTAssertEqual(payload?["longitude"], 121.3915)
  }

  func testLocateWhenInactiveAndNotDeterminedFailsWithoutWedgingAuthorization() {
    var active = false
    let single = FakeCampusMapLocationManager(authorizationStatus: .notDetermined)
    let controller = CampusMapLocationController(
      makeManager: { single },
      checkServicesEnabled: { $0(true) },
      isAppActive: { active },
      locateTimeoutSeconds: 5,
      activeRecheckDelaySeconds: 0,
      notificationCenter: NotificationCenter()
    )

    var firstResponse: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { firstResponse = $0 }
    XCTAssertEqual((firstResponse as? FlutterError)?.code, "location_unavailable")
    XCTAssertEqual(single.requestWhenInUseCount, 0)

    active = true
    var secondResponse: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { secondResponse = $0 }
    XCTAssertEqual(single.requestWhenInUseCount, 1)
    single.simulateAuthorizationChange(.denied)
    XCTAssertEqual((secondResponse as? FlutterError)?.code, "permission_denied")
  }

  func testLocateWhileWatchingRequestsSingleLocationWhenCachedFixIsStaleOrCoarse() {
    let single = FakeCampusMapLocationManager(authorizationStatus: .authorizedWhenInUse)
    let watch = FakeCampusMapLocationManager(authorizationStatus: .authorizedWhenInUse)
    var created = 0
    let controller = CampusMapLocationController(
      makeManager: {
        created += 1
        return created == 1 ? watch : single
      },
      checkServicesEnabled: { $0(true) },
      isAppActive: { true },
      locateTimeoutSeconds: 5,
      notificationCenter: NotificationCenter()
    )

    var events: [Any?] = []
    _ = controller.onListen(withArguments: nil) { events.append($0) }
    XCTAssertEqual(watch.startUpdatingCount, 1)
    // Stale (>5s) and coarse (>65m) cached fix from stationary/reduced-accuracy watch.
    watch.location = makeLocation(accuracy: 120, ageSeconds: 12)

    var locateResponse: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { locateResponse = $0 }
    XCTAssertEqual(single.requestLocationCount, 1)

    single.simulateLocations([makeLocation(latitude: 31.32, longitude: 121.40, accuracy: 15)])
    let payload = locateResponse as? [String: Double]
    XCTAssertEqual(payload?["latitude"], 31.32)
    XCTAssertEqual(payload?["longitude"], 121.40)
    XCTAssertTrue(events.isEmpty)
  }

  func testOnCancelDoesNotInterruptInFlightSingleLocate() {
    let single = FakeCampusMapLocationManager(authorizationStatus: .authorizedWhenInUse)
    let watch = FakeCampusMapLocationManager(authorizationStatus: .authorizedWhenInUse)
    var created = 0
    let controller = CampusMapLocationController(
      makeManager: {
        created += 1
        return created == 1 ? single : watch
      },
      checkServicesEnabled: { $0(true) },
      isAppActive: { true },
      locateTimeoutSeconds: 5,
      notificationCenter: NotificationCenter()
    )

    var locateResponse: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { locateResponse = $0 }
    XCTAssertEqual(single.requestLocationCount, 1)

    _ = controller.onListen(withArguments: nil) { _ in }
    _ = controller.onCancel(withArguments: nil)
    XCTAssertEqual(watch.stopUpdatingCount, 1)
    XCTAssertEqual(single.stopUpdatingCount, 0)

    single.simulateLocations([makeLocation()])
    XCTAssertEqual((locateResponse as? [String: Double])?["accuracy"], 10)
  }

  func testRestrictedAuthorizationMapsToPermissionDeniedWithoutSettingsAction() {
    let single = FakeCampusMapLocationManager(authorizationStatus: .restricted)
    let controller = CampusMapLocationController(
      makeManager: { single },
      checkServicesEnabled: { $0(true) },
      isAppActive: { true },
      notificationCenter: NotificationCenter()
    )

    var response: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "permission_denied")
  }

  func testInvalidLocationsAreIgnoredAndTimeoutCompletesCleanly() {
    let single = FakeCampusMapLocationManager(authorizationStatus: .authorizedWhenInUse)
    let controller = CampusMapLocationController(
      makeManager: { single },
      checkServicesEnabled: { $0(true) },
      isAppActive: { true },
      locateTimeoutSeconds: 0.05,
      notificationCenter: NotificationCenter()
    )

    let expectation = expectation(description: "locate timeout")
    var response: Any?
    controller.handle(FlutterMethodCall(methodName: "locate", arguments: nil)) {
      response = $0
      expectation.fulfill()
    }

    single.simulateLocations([
      makeLocation(accuracy: -1),
      makeLocation(accuracy: .infinity),
      makeLocation(latitude: 999, longitude: 999, accuracy: 10),
    ])
    XCTAssertNil(response)

    wait(for: [expectation], timeout: 1)
    XCTAssertEqual((response as? FlutterError)?.code, "timeout")
    XCTAssertEqual(single.stopUpdatingCount, 1)
  }

  func testWatchIgnoresTransientLocationUnknownAndStopsOnDenied() {
    let watch = FakeCampusMapLocationManager(authorizationStatus: .authorizedWhenInUse)
    let controller = CampusMapLocationController(
      makeManager: { watch },
      checkServicesEnabled: { $0(true) },
      isAppActive: { true },
      notificationCenter: NotificationCenter()
    )

    var events: [Any?] = []
    _ = controller.onListen(withArguments: nil) { events.append($0) }
    watch.simulateError(CLError(.locationUnknown))
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(watch.stopUpdatingCount, 0)

    watch.authorizationStatus = .denied
    watch.simulateError(CLError(.denied))
    XCTAssertEqual((events.last as? FlutterError)?.code, "permission_denied_forever")
    XCTAssertEqual(watch.stopUpdatingCount, 1)
  }
}
