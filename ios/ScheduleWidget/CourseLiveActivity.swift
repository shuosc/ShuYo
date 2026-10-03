import ActivityKit
import SwiftUI
import WidgetKit

/// Two columns in every presentation: where on the leading side, when on the trailing side.
@available(iOSApplicationExtension 26.0, *)
struct CourseLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CourseActivityAttributes.self) { context in
      CourseLiveActivityLockScreenView(state: context.state, isStale: context.isStale)
        .activitySystemActionForegroundColor(.primary)
        .widgetURL(scheduleURL)
    } dynamicIsland: { context in
      let needsFullWidthHeader = CourseActivityLocation(context.state.location).room == nil
      return DynamicIsland {
        // The compact pair grows in place beside the camera.
        DynamicIslandExpandedRegion(.leading) {
          if !needsFullWidthHeader {
            CourseActivityDestinationView(location: context.state.location)
              .modifier(CourseActivityExpandedLine(role: .destination))
              .dynamicIsland(verticalPlacement: .belowIfTooWide)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          if !needsFullWidthHeader {
            CourseActivityRelativeTimeView(state: context.state, isStale: context.isStale)
              .modifier(CourseActivityExpandedLine(role: .time))
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 10) {
            // Named venues use a shared row below the camera so the time moves
            // with the destination instead of remaining in a separate region.
            if needsFullWidthHeader {
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                CourseActivityDestinationView(location: context.state.location)
                  .modifier(CourseActivityExpandedLine(role: .destination))
                Spacer(minLength: 0)
                CourseActivityRelativeTimeView(state: context.state, isStale: context.isStale)
                  .modifier(CourseActivityExpandedLine(role: .time))
                  .layoutPriority(1)
              }
            }
            CourseActivityDetailsView(state: context.state, isStale: context.isStale)
            CourseActivityProgressView(state: context.state, isStale: context.isStale)
          }
        }
      } compactLeading: {
        CourseActivityCompactView(state: context.state, isStale: context.isStale, isTrailing: false)
      } compactTrailing: {
        CourseActivityCompactView(state: context.state, isStale: context.isStale, isTrailing: true)
      } minimal: {
        CourseActivityMinimalView(state: context.state, isStale: context.isStale)
      }
      // Margins apply to the complete presentation, including both regions beside
      // the camera, so content stays concentric with the rounded outer corners.
      .contentMargins(.horizontal, 28, for: .expanded)
      .contentMargins(.top, 19, for: .expanded)
      .contentMargins(.bottom, 28, for: .expanded)
      .widgetURL(scheduleURL)
      .keylineTint(ScheduleWidgetPalette.darkAccent)
    }
  }
}

/// The system owns backgrounds, outer corners, and presentation transitions.
@available(iOSApplicationExtension 26.0, *)
struct CourseLiveActivityLockScreenView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(spacing: 10) {
      VStack(spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          CourseActivityDestinationView(location: state.location)
            .font(.system(.title, design: .rounded, weight: .bold))
          Spacer(minLength: 0)
          CourseActivityRelativeTimeView(state: state, isStale: isStale)
            .font(.system(.title2, design: .rounded, weight: .semibold))
            .layoutPriority(1)
        }
        CourseActivityDetailsView(state: state, isStale: isStale)
      }
      .accessibilityElement(children: .combine)
      // Once class has started the bar has nothing left to measure; the platter gets shorter.
      CourseActivityProgressView(state: state, isStale: isStale)
    }
    .padding(14)
  }
}

/// The system lays out the expanded leading and trailing regions independently.
/// Both carry the same hidden line box, so the room and the time share a baseline.
@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityExpandedLine: ViewModifier {
  enum Role { case destination, time }

  let role: Role

  private var destinationFont: Font {
    .system(.title, design: .rounded, weight: .bold)
  }

  private var timeFont: Font {
    .system(.title2, design: .rounded, weight: .semibold)
  }

  func body(content: Content) -> some View {
    ZStack(alignment: role == .destination ? .leadingFirstTextBaseline : .trailingFirstTextBaseline) {
      Text("D国").font(destinationFont).hidden()
      Text("0国").font(timeFont).hidden()
      content.font(role == .destination ? destinationFont : timeFont)
    }
  }
}

@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityCompactView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool
  let isTrailing: Bool

  var body: some View {
    if #available(iOSApplicationExtension 27.0, *) {
      CourseActivityWidthAwareCompactView(state: state, isStale: isStale, isTrailing: isTrailing)
    } else {
      CourseActivityCompactContent(state: state, isStale: isStale, isTrailing: isTrailing, isLimited: false)
    }
  }
}

@available(iOSApplicationExtension 27.0, *)
private struct CourseActivityWidthAwareCompactView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool
  let isTrailing: Bool
  @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited

  var body: some View {
    CourseActivityCompactContent(state: state, isStale: isStale, isTrailing: isTrailing, isLimited: isLimited)
  }
}

/// Reads as one phrase in a single color and weight: “DJ304 14分钟后”.
@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityCompactContent: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool
  let isTrailing: Bool
  let isLimited: Bool

  var body: some View {
    Group {
      if isLimited {
        // The limited host clips two equal, adjacent compact regions separately.
        // Render the same centered label in their shared coordinate space so the
        // room stays intact and its alignment does not depend on prefix length.
        GeometryReader { geometry in
          Text(CourseActivityLocation(state.location).room ?? "上课")
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: geometry.size.width * 2, height: geometry.size.height)
            .offset(x: isTrailing ? -geometry.size.width : 0)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("上课地点：\(state.location)")
        .accessibilityHidden(isTrailing)
      } else if isTrailing {
        CourseActivityRelativeTimeView(state: state, isStale: isStale)
          .minimumScaleFactor(0.8)
      } else if let room = CourseActivityLocation(state.location).room {
        Text(room)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .accessibilityLabel("上课地点：\(room)")
      } else {
        Image(systemName: "mappin")
          .accessibilityLabel("上课地点：\(state.location)")
      }
    }
    .font(.system(.subheadline, design: .rounded, weight: .semibold))
    .foregroundStyle(ScheduleWidgetPalette.darkAccent)
  }
}

/// The ring is the one thing in the minimal presentation that changes over time.
@available(iOSApplicationExtension 26.0, *)
struct CourseActivityMinimalView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    ZStack {
      if !CourseActivityPresentation.reminderHasEnded(state, isStale: isStale) {
        ProgressView(
          timerInterval: CourseActivityPresentation.progressInterval(state), countsDown: false
        ) {
          EmptyView()
        } currentValueLabel: {
          EmptyView()
        }
        .progressViewStyle(.circular)
        .tint(ScheduleWidgetPalette.darkAccent)
        .frame(width: 25, height: 25)
      }
      Image(systemName: "graduationcap.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(ScheduleWidgetPalette.darkAccent)
    }
    .frame(width: 30, height: 30)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(state.courseName)，上课地点：\(state.location)，\(CourseActivityPresentation.time(state.startsAt))上课")
  }
}

/// The room alone when the location contains one; otherwise the whole location.
/// Callers choose the font.
@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityDestinationView: View {
  let location: String

  var body: some View {
    let destination = CourseActivityLocation(location)
    Text(destination.room ?? destination.full)
      .fontWeight(.bold)
      .fontDesign(.rounded)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .accessibilityLabel("上课地点：\(destination.full)")
  }
}

/// The static measuring text determines size; the live text never expands its column.
@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityRelativeTimeView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool
  @Environment(\.colorScheme) private var colorScheme

  private var measuringText: String {
    let minutes = max(0, ceil(state.startsAt.timeIntervalSince(state.visibleFrom) / 60))
    let digits = max(2, String(Int(minutes)).count)
    return String(repeating: "0", count: digits) + "分钟后"
  }

  var body: some View {
    let hasEnded = CourseActivityPresentation.reminderHasEnded(state, isStale: isStale)
    Text(measuringText)
      .monospacedDigit()
      .fixedSize()
      .hidden()
      .overlay(alignment: .trailing) {
        Group {
          if hasEnded {
            Text("已上课")
          } else {
            Text(.currentDate, format: .reference(
              to: state.startsAt, allowedFields: [.minute]
            ).locale(Locale(identifier: "zh_Hans_CN")))
              .fontWeight(.semibold)
              .fontDesign(.rounded)
          }
        }
        .foregroundStyle(hasEnded ? Color.secondary : ScheduleWidgetPalette.accent(for: colorScheme))
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
      }
  }
}

@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityDetailsView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(metadata)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel(CourseActivityPresentation.courseAndCampus(state))
      Spacer(minLength: 0)
      Text(CourseActivityPresentation.absoluteTime(state, isStale: isStale))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
        .layoutPriority(1)
    }
    .font(.subheadline.weight(.medium))
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var metadata: AttributedString {
    var course = AttributedString(state.courseName)
    course.foregroundColor = .primary
    if let campus = CourseActivityPresentation.campus(state.campus) {
      var suffix = AttributedString(" · \(campus)")
      suffix.foregroundColor = .secondary
      course.append(suffix)
    }
    return course
  }
}

/// The system animates the bar from `visibleFrom` to the start of class.
@available(iOSApplicationExtension 26.0, *)
private struct CourseActivityProgressView: View {
  let state: CourseActivityAttributes.ContentState
  let isStale: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if !CourseActivityPresentation.reminderHasEnded(state, isStale: isStale) {
      ProgressView(
        timerInterval: CourseActivityPresentation.progressInterval(state), countsDown: false
      ) {
        EmptyView()
      } currentValueLabel: {
        EmptyView()
      }
      .progressViewStyle(.linear)
      .tint(ScheduleWidgetPalette.accent(for: colorScheme))
      .frame(height: 4)
      .scaleEffect(x: 1, y: 1.5)
      .frame(height: 6)
      .background {
        Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08))
      }
      .clipShape(Capsule())
      .accessibilityLabel("距离上课")
    }
  }
}

/// Extract the room without hiding a partially truncated room ID.
/// Unstructured locations stay intact in the large presentations.
private struct CourseActivityLocation {
  let full: String
  let room: String?
  private static let roomPattern = try? NSRegularExpression(
    pattern: "(?<![A-Za-z0-9])[A-Za-z]{1,3}(?:[-–][A-Za-z]{0,2})?\\d{2,4}[A-Za-z]?(?![A-Za-z0-9])"
  )

  init(_ value: String) {
    full = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = Self.roomPattern?.matches(
      in: full, range: NSRange(full.startIndex..., in: full)
    ).last, let range = Range(match.range, in: full) {
      let code = String(full[range])
      // Very long identifiers belong in expanded views, not in the status bar.
      room = code.count <= 8 ? code : nil
    } else {
      room = nil
    }
  }
}

@available(iOSApplicationExtension 26.0, *)
private enum CourseActivityPresentation {
  static let format = Date.FormatStyle(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

  static func time(_ date: Date) -> String { date.formatted(format) }

  /// Switch at class start; expiresAt only controls how long the activity is retained.
  static func reminderHasEnded(_ state: CourseActivityAttributes.ContentState, isStale: Bool) -> Bool {
    isStale || Date() >= state.startsAt
  }

  static func progressInterval(_ state: CourseActivityAttributes.ContentState) -> ClosedRange<Date> {
    // Equal visibility/start dates are valid input; keep the system timer range nonempty.
    min(state.visibleFrom, state.startsAt.addingTimeInterval(-1))...state.startsAt
  }

  static func campus(_ value: String?) -> String? {
    guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else { return nil }
    return name.hasSuffix("校区") ? name : "\(name)校区"
  }

  static func courseAndCampus(_ state: CourseActivityAttributes.ContentState) -> String {
    campus(state.campus).map { "\(state.courseName) · \($0)" } ?? state.courseName
  }

  /// Uses the same class-start boundary as the relative time and progress views.
  static func absoluteTime(_ state: CourseActivityAttributes.ContentState, isStale: Bool) -> String {
    reminderHasEnded(state, isStale: isStale)
      ? "\(time(state.endsAt)) 下课"
      : "\(time(state.startsAt)) 上课"
  }
}
