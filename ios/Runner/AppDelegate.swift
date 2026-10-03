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
            await self?.syncEarlyClassAlarms(alarms, result: result)
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
    private func syncEarlyClassAlarms(
      _ rawAlarms: [[String: Any]],
      result: @escaping FlutterResult
    ) async {
      let manager = AlarmManager.shared
      let defaults = UserDefaults.standard
      do {
        let currentIDs = Set(try manager.alarms.map(\.id))
        for rawID in defaults.stringArray(forKey: Self.earlyClassAlarmIdsKey) ?? [] {
          guard
            let id = UUID(uuidString: rawID),
            currentIDs.contains(id)
          else { continue }
          try manager.cancel(id: id)
        }
      } catch {
        result(
          FlutterError(
            code: "alarm_cancel_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }
      defaults.removeObject(forKey: Self.earlyClassAlarmIdsKey)

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
      var scheduledIDs: [String] = []

      for (date, title) in alarms {
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
          try await manager.schedule(id: id, configuration: configuration)
          scheduledIDs.append(id.uuidString)
          defaults.set(scheduledIDs, forKey: Self.earlyClassAlarmIdsKey)
        } catch AlarmManager.AlarmError.maximumLimitReached {
          break
        } catch {
          defaults.set(scheduledIDs, forKey: Self.earlyClassAlarmIdsKey)
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

      defaults.set(scheduledIDs, forKey: Self.earlyClassAlarmIdsKey)
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
