import ActivityKit
import Foundation

@available(iOS 26.0, *)
struct CourseActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    let courseName: String
    let location: String
    let campus: String?
    let startsAt: Date
    let endsAt: Date
    let visibleFrom: Date
    let expiresAt: Date
  }

  let occurrenceID: String
}
