import SwiftUI
import WidgetKit

private let appGroupID = "group.work.shuyo.app"
private let snapshotKey = "academic_schedule_widget_snapshot"
let scheduleURL = URL(string: "shuyo://schedule?homeWidget")

enum ScheduleWidgetPalette {
  static let lightAccent = Color(red: 41 / 255.0, green: 148 / 255.0, blue: 242 / 255.0)
  static let darkAccent = Color(red: 65 / 255.0, green: 174 / 255.0, blue: 242 / 255.0)

  static func accent(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? darkAccent : lightAccent
  }
}

private struct ScheduleSnapshot: Decodable {
  let hasSchedule: Bool
  let term: String?
  let maxWeek: Int?
  let currentWeek: Int?
  let anchorMonday: String?
  let sessions: [WidgetCourse]?

  var courses: [WidgetCourse] { sessions ?? [] }
  var lastWeek: Int { max(maxWeek ?? 1, 1) }

  static func load() -> ScheduleSnapshot? {
    guard
      let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: snapshotKey),
      let data = raw.data(using: .utf8),
      let snapshot = try? JSONDecoder().decode(ScheduleSnapshot.self, from: data),
      snapshot.hasSchedule
    else {
      return nil
    }
    return snapshot
  }

  func activeWeek(on date: Date, calendar: Calendar) -> Int {
    let vacationWeek = lastWeek + 1
    guard
      let anchorMonday,
      let anchor = Self.parseDate(anchorMonday),
      let monday = calendar.dateInterval(of: .weekOfYear, for: date)?.start
    else {
      return min(max(currentWeek ?? 1, 0), vacationWeek)
    }
    let anchorDay = calendar.startOfDay(for: anchor)
    let offset = calendar.dateComponents([.weekOfYear], from: anchorDay, to: monday)
      .weekOfYear ?? 0
    return min(max((currentWeek ?? 1) + offset, 0), vacationWeek)
  }

  func courses(on date: Date, calendar: Calendar) -> [WidgetCourse] {
    let week = activeWeek(on: date, calendar: calendar)
    guard (1...lastWeek).contains(week) else { return [] }
    let weekday = ((calendar.component(.weekday, from: date) + 5) % 7) + 1
    return courses
      .filter { $0.weekday == weekday && $0.occurs(in: week) }
      .sorted {
        $0.startMinute == $1.startMinute ? $0.name < $1.name : $0.startMinute < $1.startMinute
      }
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }

    let dayFormatter = DateFormatter()
    dayFormatter.calendar = Calendar(identifier: .gregorian)
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.dateFormat = "yyyy-MM-dd"
    return dayFormatter.date(from: String(value.prefix(10)))
  }
}

private struct WidgetCourse: Decodable, Identifiable {
  let id: String
  let name: String
  let room: String?
  let meta: String?
  let weekday: Int
  let weeks: [Int]
  let startMinute: Int
  let endMinute: Int
  let startText: String?
  let endText: String?
  let sectionText: String?

  func occurs(in week: Int) -> Bool { weeks.isEmpty || weeks.contains(week) }
  func isActive(at minute: Int) -> Bool { (startMinute...endMinute).contains(minute) }

  var timeText: String {
    "\(startDisplayText)-\(endDisplayText)"
  }

  var startDisplayText: String { startText ?? Self.format(startMinute) }
  var endDisplayText: String { endText ?? Self.format(endMinute) }

  var detailText: String {
    let value = meta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !value.isEmpty { return value }
    return sectionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  var compactPlace: String {
    let value = room?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !value.isEmpty { return value }
    return sectionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func format(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
  }
}

private struct ScheduleEntry: TimelineEntry {
  let date: Date
  let snapshot: ScheduleSnapshot?
}

private struct ScheduleProvider: TimelineProvider {
  func placeholder(in context: Context) -> ScheduleEntry {
    ScheduleEntry(date: Date(), snapshot: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
    completion(ScheduleEntry(date: Date(), snapshot: ScheduleSnapshot.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
    let now = Date()
    let snapshot = ScheduleSnapshot.load()
    let dates = transitionDates(after: now, snapshot: snapshot)
    let entries = dates.map { ScheduleEntry(date: $0, snapshot: snapshot) }
    completion(Timeline(entries: entries, policy: .atEnd))
  }

  private func transitionDates(after now: Date, snapshot: ScheduleSnapshot?) -> [Date] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    var dates: Set<Date> = [now]
    let today = calendar.startOfDay(for: now)

    for dayOffset in 0...2 {
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
      if day > now { dates.insert(day) }
      guard let snapshot else { continue }
      for course in snapshot.courses(on: day, calendar: calendar) {
        if let start = calendar.date(byAdding: .minute, value: course.startMinute, to: day),
           start > now {
          dates.insert(start)
        }
        if let end = calendar.date(byAdding: .minute, value: course.endMinute + 1, to: day),
           end > now {
          dates.insert(end)
        }
      }
    }
    return dates.sorted()
  }
}

private struct SchedulePresentation {
  let title: String
  let meta: String
  let status: String
  let compactDetail: String
  let courses: [WidgetCourse]
  let nowMinute: Int
  let showingTomorrow: Bool

  static func make(snapshot: ScheduleSnapshot?, at date: Date) -> SchedulePresentation? {
    guard let snapshot else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    let nowMinute = calendar.component(.hour, from: date) * 60
      + calendar.component(.minute, from: date)
    let week = snapshot.activeWeek(on: date, calendar: calendar)
    let todayCourses = snapshot.courses(on: date, calendar: calendar)
    let remaining = todayCourses.filter { $0.endMinute >= nowMinute }
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
    let tomorrowCourses = remaining.isEmpty
      ? snapshot.courses(on: tomorrow, calendar: calendar)
      : []
    let showingTomorrow = !tomorrowCourses.isEmpty
    let visible = showingTomorrow ? tomorrowCourses : remaining
    let displayDate = showingTomorrow ? tomorrow : date
    let displayWeek = snapshot.activeWeek(on: displayDate, calendar: calendar)
    let vacation = !(1...snapshot.lastWeek).contains(week)
    let weekday = weekdayName(for: displayDate, calendar: calendar)
    let next = visible.first

    let status: String
    let compactDetail: String
    if showingTomorrow, let next {
      status = "明天的课程"
      let prefix = "明天 \(next.startText ?? "")"
      compactDetail = next.compactPlace.isEmpty ? prefix : "\(prefix) · \(next.compactPlace)"
    } else if vacation {
      status = "假期中"
      compactDetail = ""
    } else if todayCourses.isEmpty {
      status = "明日暂无课程"
      compactDetail = ""
    } else if next == nil {
      status = "明日暂无课程"
      compactDetail = ""
    } else if next!.isActive(at: nowMinute) {
      status = "正在上课 · \(next!.name)"
      compactDetail = "正在上课 · \(next!.compactPlace)"
    } else {
      status = "下一节 \(next!.startText ?? "") · \(next!.name)"
      compactDetail = "下一节 \(next!.startText ?? "") · \(next!.compactPlace)"
    }

    let meta = showingTomorrow || !vacation
      ? "第\(displayWeek)周 · \(weekday)"
      : "假期中 · \(weekdayName(for: date, calendar: calendar))"
    return SchedulePresentation(
      title: snapshot.term?.isEmpty == false ? snapshot.term! : "ShuYo课表",
      meta: meta,
      status: status,
      compactDetail: compactDetail,
      courses: visible,
      nowMinute: showingTomorrow ? -1 : nowMinute,
      showingTomorrow: showingTomorrow
    )
  }

  private static func weekdayName(for date: Date, calendar: Calendar) -> String {
    let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    return names[calendar.component(.weekday, from: date) - 1]
  }
}

private struct ScheduleWidgetView: View {
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var colorScheme
  let entry: ScheduleEntry

  var body: some View {
    Group {
      if let presentation = SchedulePresentation.make(snapshot: entry.snapshot, at: entry.date) {
        if family == .systemSmall {
          compactView(presentation)
        } else if family == .systemLarge {
          largeCourseList(presentation)
        } else {
          courseList(presentation, count: 2)
        }
      } else {
        emptyView
      }
    }
    .widgetURL(scheduleURL)
    .scheduleWidgetBackground(backgroundColor)
  }

  private func compactView(_ value: SchedulePresentation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("课表").font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 4)
        Text(value.meta).font(.system(size: 10)).foregroundColor(.secondary)
      }
      Spacer(minLength: 0)
      Text(value.courses.first?.name ?? value.status)
        .font(.system(size: 17, weight: .semibold))
        .lineLimit(2)
      Text(value.compactDetail)
        .font(.system(size: 11))
        .foregroundColor(accentColor)
        .lineLimit(1)
        .frame(minHeight: 14)
    }
  }

  private func courseList(_ value: SchedulePresentation, count: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(value.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 8)
        Text(value.meta).font(.system(size: 11)).foregroundColor(.secondary)
      }
      Text(value.status)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(accentColor)
        .lineLimit(1)
      ForEach(Array(value.courses.prefix(count))) { course in
        courseRow(course, active: course.isActive(at: value.nowMinute))
      }
      Spacer(minLength: 0)
    }
  }

  private func largeCourseList(_ value: SchedulePresentation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(value.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 8)
        Text(value.meta).font(.system(size: 11)).foregroundColor(.secondary)
      }
      Text(value.status)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(accentColor)
        .lineLimit(1)
      GeometryReader { proxy in
        let rowHeight = max((proxy.size.height - 18) / 4, 0)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(value.courses.prefix(4))) { course in
            courseRow(
              course,
              active: course.isActive(at: value.nowMinute),
              fillsAvailableHeight: true,
              usesLargeTypography: true
            )
              .frame(height: rowHeight)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  private func courseRow(
    _ course: WidgetCourse,
    active: Bool,
    fillsAvailableHeight: Bool = false,
    usesLargeTypography: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      if usesLargeTypography {
        VStack(alignment: .leading, spacing: 2) {
          Text(course.startDisplayText)
          Text(course.endDisplayText)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundColor(.secondary)
        .frame(width: 42, alignment: .leading)
      } else {
        Text(course.timeText)
          .font(.system(size: 10, design: .rounded))
          .foregroundColor(.secondary)
          .frame(width: 72, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(course.name)
          .font(.system(size: usesLargeTypography ? 15 : 12, weight: .semibold))
          .lineLimit(1)
        Text(course.detailText)
          .font(.system(size: usesLargeTypography ? 12 : 10))
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: .leading
    )
    .background(active ? activeRowColor : rowColor)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("ShuYo课表").font(.system(size: 15, weight: .semibold))
      Spacer()
      Text("打开 ShuYo 同步课表")
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(accentColor)
      Text("本地还没有可显示的课程缓存")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }
  }

  private var backgroundColor: Color {
    colorScheme == .dark
      ? Color(red: 21 / 255, green: 23 / 255, blue: 25 / 255)
      : Color(red: 247 / 255, green: 247 / 255, blue: 244 / 255)
  }

  private var rowColor: Color {
    colorScheme == .dark
      ? Color(red: 27 / 255, green: 32 / 255, blue: 37 / 255)
      : .white
  }

  private var activeRowColor: Color {
    colorScheme == .dark
      ? Color(red: 16 / 255, green: 43 / 255, blue: 61 / 255)
      : Color(red: 230 / 255, green: 242 / 255, blue: 254 / 255)
  }

  private var accentColor: Color {
    ScheduleWidgetPalette.accent(for: colorScheme)
  }
}

private extension View {
  @ViewBuilder
  func scheduleWidgetBackground(_ color: Color) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(color, for: .widget)
    } else {
      background(color)
    }
  }
}

struct ScheduleWidget: Widget {
  let kind = "ScheduleWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
      ScheduleWidgetView(entry: entry)
    }
    .configurationDisplayName("ShuYo课表")
    .description("查看当前、下一节与明日课程。")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

@main
struct ShuYoWidgetBundle: WidgetBundle {
  @WidgetBundleBuilder
  var body: some Widget {
    ScheduleWidget()
    if #available(iOSApplicationExtension 26.0, *) {
      CourseLiveActivity()
    }
  }
}
