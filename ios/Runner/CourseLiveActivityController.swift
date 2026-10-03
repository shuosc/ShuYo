import ActivityKit
import Flutter
import UIKit

/// Owns the local ActivityKit queue; the schedule remains the Dart repository's responsibility.
@MainActor
final class CourseLiveActivityController {
  private let defaults: UserDefaults
  private var syncTask: Task<Void, Never>?
  private static let requestedKey = "course_live_activity_requested_occurrences"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "isAvailable" {
      if #available(iOS 26.0, *) {
        result(true)
      } else {
        result(false)
      }
      return
    }
    guard call.method == "sync" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let enabled = arguments["enabled"] as? Bool,
      let rawCourses = arguments["courses"] as? [[String: Any]]
    else {
      result(FlutterError(code: "invalid_courses", message: "Expected course activity settings", details: nil))
      return
    }
    guard #available(iOS 26.0, *) else {
      result(["scheduledOccurrenceIDs": [], "activitiesEnabled": false])
      return
    }

    // Calls can overlap after a course edit or a settings change. Preserve their order.
    let previous = syncTask
    syncTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      result(await self.reconcile(enabled: enabled, rawCourses: rawCourses))
    }
  }

  @available(iOS 26.0, *)
  private func reconcile(enabled: Bool, rawCourses: [[String: Any]]) async -> [String: Any] {
    let now = Date()
    // Dart plans and limits the queue; it sends no courses when disabled.
    let desired = rawCourses.compactMap(CourseActivityRequest.init)
      .filter { $0.state.expiresAt > now }
    let desiredIDs = Set(desired.map(\.occurrenceID))
    let desiredReservations = desired.reduce(into: [String: CourseActivityReservationLedger.Reservation]()) {
      $0[$1.occurrenceID] = .init(visibleFrom: $1.state.visibleFrom, expiresAt: $1.state.expiresAt)
    }
    var ledger = CourseActivityReservationLedger(
      stored: defaults.dictionary(forKey: Self.requestedKey) ?? [:],
      legacyReservations: desiredReservations
    )
    var existing = [String: Activity<CourseActivityAttributes>]()

    for activity in Activity<CourseActivityAttributes>.activities {
      let id = activity.attributes.occurrenceID
      guard activity.activityState != .dismissed, activity.activityState != .ended else { continue }
      if !desiredIDs.contains(id) || activity.content.state.expiresAt <= now
        || existing[id] != nil {
        await activity.end(nil, dismissalPolicy: .immediate)
        if existing[id] == nil { ledger.remove(id) }
      } else {
        existing[id] = activity
      }
    }

    let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    ledger.reconcile(
      enabled: enabled && activitiesEnabled, desiredIDs: desiredIDs,
      existingIDs: Set(existing.keys), now: now
    )
    guard enabled, activitiesEnabled else {
      for activity in existing.values {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      defaults.set(ledger.storedValues, forKey: Self.requestedKey)
      return ["scheduledOccurrenceIDs": [], "activitiesEnabled": activitiesEnabled]
    }

    for course in desired {
      let id = course.occurrenceID
      // Trigger the "class started" presentation even if the host is suspended.
      // expiresAt is cleaned up on the next reconcile; it does not schedule a
      // background end. Likewise, staleDate changes presentation without ending it.
      let content = ActivityContent(state: course.state, staleDate: course.state.startsAt)
      let alert = AlertConfiguration(
        title: LocalizedStringResource(stringLiteral: course.state.courseName),
        body: LocalizedStringResource(stringLiteral: "即将上课 · \(course.state.location)"),
        sound: .default
      )
      var replacing = false
      if let activity = existing[id] {
        if activity.activityState == .pending,
          activity.content.state.visibleFrom != course.state.visibleFrom {
          // A pending activity's scheduled start can't be moved with update().
          await activity.end(nil, dismissalPolicy: .immediate)
          existing.removeValue(forKey: id)
          ledger.remove(id)
          replacing = true
        } else {
          if activity.activityState != .pending || !ledger.contains(id) {
            let visibleFrom = activity.activityState == .pending
              ? activity.content.state.visibleFrom : min(activity.content.state.visibleFrom, now)
            ledger.record(id, visibleFrom: visibleFrom, expiresAt: course.state.expiresAt)
          }
          if activity.content.state != course.state {
            await activity.update(content)
          }
          continue
        }
      }

      // Do not resurrect a dismissed activity, or create a new reminder after class starts.
      guard (!ledger.contains(id) || replacing), course.state.startsAt > Date(),
        UIApplication.shared.applicationState == .active
      else { continue }
      do {
        let activity: Activity<CourseActivityAttributes>
        let attributes = CourseActivityAttributes(occurrenceID: id)
        if course.state.visibleFrom > Date() {
          activity = try Activity.request(
            attributes: attributes, content: content, pushType: nil, style: .standard,
            alertConfiguration: alert,
            start: course.state.visibleFrom
          )
        } else {
          activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
          // Alert updates use the system's expanded Island presentation and automatic collapse.
          await activity.update(content, alertConfiguration: alert)
        }
        existing[id] = activity
        ledger.record(id, visibleFrom: course.state.visibleFrom, expiresAt: course.state.expiresAt)
      } catch {
        // Other apps share the system limit. Keep successes and retry remaining courses on resume.
        break
      }
    }
    let existingIDs = Set(existing.compactMap { id, activity in
      activity.activityState != .dismissed && activity.activityState != .ended ? id : nil
    })
    // ActivityKit can remove a reservation during an awaited update or request.
    ledger.reconcile(enabled: true, desiredIDs: desiredIDs, existingIDs: existingIDs, now: Date())
    defaults.set(ledger.storedValues, forKey: Self.requestedKey)
    // A partial queue must still acknowledge its successes, otherwise Dart could
    // schedule a second notification for a course already owned by ActivityKit.
    // Only history for activities whose display time has arrived suppresses a
    // repeated reminder after dismissal. A missing future reservation uses fallback.
    let confirmedIDs = desired.compactMap { course in
      existingIDs.contains(course.occurrenceID) || ledger.contains(course.occurrenceID)
        ? course.occurrenceID : nil
    }
    return ["scheduledOccurrenceIDs": confirmedIDs, "activitiesEnabled": true]
  }
}

/// Keeps pending reservations separate from dismissal history without depending on ActivityKit.
struct CourseActivityReservationLedger {
  struct Reservation: Equatable {
    let visibleFrom: Date
    let expiresAt: Date
  }

  private var reservations: [String: Reservation] = [:]

  init(stored: [String: Any], legacyReservations: [String: Reservation]) {
    for (id, value) in stored {
      if let fields = value as? [String: Double],
        let visibleFrom = fields["visibleFrom"], let expiresAt = fields["expiresAt"] {
        reservations[id] = Reservation(
          visibleFrom: Date(timeIntervalSince1970: visibleFrom),
          expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
      } else if let expiresAt = value as? Double, let desired = legacyReservations[id] {
        // Older versions persisted only expiration; use the current plan to migrate it.
        reservations[id] = Reservation(
          visibleFrom: desired.visibleFrom, expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
      }
    }
  }

  mutating func reconcile(enabled: Bool, desiredIDs: Set<String>, existingIDs: Set<String>, now: Date) {
    guard enabled else {
      reservations.removeAll()
      return
    }
    reservations = reservations.filter { id, reservation in
      reservation.expiresAt > now && desiredIDs.contains(id)
        && (existingIDs.contains(id) || reservation.visibleFrom <= now)
    }
  }

  mutating func record(_ id: String, visibleFrom: Date, expiresAt: Date) {
    reservations[id] = Reservation(visibleFrom: visibleFrom, expiresAt: expiresAt)
  }

  mutating func remove(_ id: String) {
    reservations.removeValue(forKey: id)
  }

  func contains(_ id: String) -> Bool {
    reservations[id] != nil
  }

  var storedValues: [String: [String: Double]] {
    reservations.mapValues {
      ["visibleFrom": $0.visibleFrom.timeIntervalSince1970, "expiresAt": $0.expiresAt.timeIntervalSince1970]
    }
  }
}

@available(iOS 26.0, *)
struct CourseActivityRequest {
  let occurrenceID: String
  let state: CourseActivityAttributes.ContentState

  init?(_ raw: [String: Any]) {
    guard
      let id = raw["occurrenceID"] as? String,
      let name = raw["courseName"] as? String,
      let location = raw["location"] as? String,
      let startsAt = Self.date(raw["startsAt"]),
      let endsAt = Self.date(raw["endsAt"]),
      let visibleFrom = Self.date(raw["visibleFrom"]),
      let expiresAt = Self.date(raw["expiresAt"])
    else { return nil }
    occurrenceID = id
    state = CourseActivityAttributes.ContentState(
      courseName: name, location: location, campus: raw["campus"] as? String,
      startsAt: startsAt, endsAt: endsAt, visibleFrom: visibleFrom, expiresAt: expiresAt
    )
  }

  private static func date(_ raw: Any?) -> Date? {
    (raw as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
  }
}
