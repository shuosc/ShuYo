import Flutter
import Photos
import UIKit
import UserNotifications

#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
  import AlarmKit
  import SwiftUI
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pendingImageSaveResult: FlutterResult?
  private var earlyClassAlarmSyncTask: Task<Void, Never>?
  private let courseLiveActivityController = CourseLiveActivityController()

  private static let earlyClassAlarmIdsKey = "early_class_alarm_ids"
  private static let earlyClassAlarmTitlesKey = "early_class_alarm_titles"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    UserDefaults.standard.removeObject(forKey: "emoji_recents")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    FlutterMethodChannel(
      name: "work.shuyo.app/image_saver",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    ).setMethodCallHandler { [weak self] call, result in
      if call.method == "saveImage" {
        self?.saveImage(call: call, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterMethodChannel(
      name: "work.shuyo.app/early_class_alarms",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    ).setMethodCallHandler { [weak self] call, result in
      self?.handleEarlyClassAlarm(call: call, result: result)
    }
    FlutterMethodChannel(
      name: "work.shuyo.app/course_live_activity",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    ).setMethodCallHandler { [weak self] call, result in
      self?.courseLiveActivityController.handle(call, result: result)
    }
  }

  private func handleEarlyClassAlarm(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "isAvailable" {
      #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
          result(true)
        } else {
          result(false)
        }
      #else
        result(false)
      #endif
      return
    }

    #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
      if #available(iOS 26.0, *) {
        switch call.method {
        case "requestAuthorization":
          Task { @MainActor in
            do {
              let state = try await AlarmManager.shared.requestAuthorization()
              result(state == .authorized)
            } catch {
              result(
                FlutterError(
                  code: "alarm_authorization_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        case "sync":
          guard
            let arguments = call.arguments as? [String: Any],
            let enabled = arguments["enabled"] as? Bool,
            let alarms = arguments["alarms"] as? [[String: Any]]
          else {
            result(
              FlutterError(
                code: "invalid_alarms",
                message: "Expected an alarms list",
                details: nil
              )
            )
            return
          }
          let previousTask = earlyClassAlarmSyncTask
          earlyClassAlarmSyncTask = Task { @MainActor [weak self] in
            await previousTask?.value
            await self?.syncEarlyClassAlarms(alarms, enabled: enabled, result: result)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
        return
      }
    #endif

    result(
      FlutterError(
        code: "alarmkit_unavailable",
        message: "AlarmKit requires iOS 26 or later",
        details: nil
      )
    )
  }

  #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    @MainActor
    func syncEarlyClassAlarms(
      _ rawAlarms: [[String: Any]],
      enabled: Bool,
      result: @escaping FlutterResult
    ) async {
      let manager = AlarmManager.shared
      let defaults = UserDefaults.standard
      guard manager.authorizationState == .authorized else {
        result(-1)
        return
      }

      let alarms = rawAlarms.compactMap { raw -> (Date, String)? in
        guard
          let milliseconds = raw["fireTime"] as? NSNumber,
          let title = raw["title"] as? String
        else {
          return nil
        }
        let date = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        return date > Date() ? (date, title) : nil
      }
      let ownedIDs = Set(defaults.stringArray(forKey: Self.earlyClassAlarmIdsKey) ?? [])
      var titles = defaults.dictionary(forKey: Self.earlyClassAlarmTitlesKey) as? [String: String] ?? [:]
      var scheduledIDs = ownedIDs
      var pending = enabled ? alarms : []

      func persist() {
        defaults.set(scheduledIDs.sorted(), forKey: Self.earlyClassAlarmIdsKey)
        defaults.set(titles.filter { scheduledIDs.contains($0.key) }, forKey: Self.earlyClassAlarmTitlesKey)
      }

      do {
        let currentAlarms = try manager.alarms.filter { ownedIDs.contains($0.id.uuidString) }
        scheduledIDs = Set(currentAlarms.map { $0.id.uuidString })
        for alarm in currentAlarms {
          let rawID = alarm.id.uuidString
          if enabled {
            if case let .fixed(date)? = alarm.schedule {
              if let index = pending.firstIndex(where: {
                $0.0 == date && (titles[rawID] == nil || titles[rawID] == $0.1)
              }) {
                // The title is absent only when adopting alarms from an older app version.
                titles[rawID] = pending.remove(at: index).1
                continue
              }
              if date <= Date() { continue }
            }
            // Resuming the app must not stop an alarm that is already due or ringing.
            if alarm.state != .scheduled { continue }
          }
          try manager.cancel(id: alarm.id)
          scheduledIDs.remove(rawID)
          titles.removeValue(forKey: rawID)
          persist()
        }
      } catch {
        persist()
        result(
          FlutterError(
            code: "alarm_sync_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }

      schedulePendingAlarms: for (date, title) in pending.sorted(by: { $0.0 < $1.0 }) {
        guard date > Date() else { continue }
        let id = UUID()
        let localizedTitle = LocalizedStringResource(stringLiteral: title)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
          alert = AlarmPresentation.Alert(title: localizedTitle)
        } else {
          alert = AlarmPresentation.Alert(
            title: localizedTitle,
            stopButton: AlarmButton(
              text: "停止",
              textColor: .white,
              systemImageName: "stop.circle.fill"
            )
          )
        }
        let attributes = AlarmAttributes<ShuYoAlarmMetadata>(
          presentation: AlarmPresentation(alert: alert),
          tintColor: .blue
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
          schedule: .fixed(date),
          attributes: attributes
        )

        do {
          while date > Date() {
            do {
              try await manager.schedule(id: id, configuration: configuration)
              scheduledIDs.insert(id.uuidString)
              titles[id.uuidString] = title
              persist()
              break
            } catch AlarmManager.AlarmError.maximumLimitReached {
              // Refresh after the await: an earlier snapshot may now be alerting.
              let replacement = try manager.alarms.compactMap { alarm -> (id: UUID, date: Date)? in
                guard
                  scheduledIDs.contains(alarm.id.uuidString),
                  alarm.state == .scheduled,
                  case let .fixed(scheduledDate)? = alarm.schedule,
                  scheduledDate > date
                else { return nil }
                return (alarm.id, scheduledDate)
              }.max { $0.date < $1.date }

              // Do not evict anything if this request expired while scheduling.
              guard date > Date() else { break }
              // All remaining reservations are earlier, due, or already ringing.
              guard let replacement else { break schedulePendingAlarms }

              // Free the farthest owned reservation and retry the nearer alarm.
              // Each retry removes one candidate, so quota retries are bounded.
              try manager.cancel(id: replacement.id)
              scheduledIDs.remove(replacement.id.uuidString)
              titles.removeValue(forKey: replacement.id.uuidString)
              persist()
            }
          }
        } catch {
          persist()
          result(
            FlutterError(
              code: "alarm_sync_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
          return
        }
      }

      persist()
      result(scheduledIDs.count)
    }

    private struct ShuYoAlarmMetadata: AlarmMetadata {}
  #endif

  private func saveImage(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard pendingImageSaveResult == nil else {
      result(
        FlutterError(
          code: "busy",
          message: "Image saver is already running",
          details: nil
        )
      )
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let typedData = args["bytes"] as? FlutterStandardTypedData,
      let image = UIImage(data: typedData.data)
    else {
      result(
        FlutterError(
          code: "invalid_image",
          message: "Cannot decode image bytes",
          details: nil
        )
      )
      return
    }
    pendingImageSaveResult = result
    UIImageWriteToSavedPhotosAlbum(
      image,
      self,
      #selector(image(_:didFinishSavingWithError:contextInfo:)),
      nil
    )
  }

  @objc private func image(
    _ image: UIImage,
    didFinishSavingWithError error: Error?,
    contextInfo: UnsafeRawPointer
  ) {
    guard let result = pendingImageSaveResult else {
      return
    }
    pendingImageSaveResult = nil
    if let error {
      result(
        FlutterError(
          code: "save_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
      return
    }
    result(true)
  }
}
