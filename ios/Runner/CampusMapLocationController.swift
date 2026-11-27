import CoreLocation
import Flutter
import UIKit

protocol CampusMapLocationManagerDelegate: AnyObject {
  func locationManagerDidChangeAuthorization(_ manager: CampusMapLocationManaging)
  func locationManager(_ manager: CampusMapLocationManaging, didUpdateLocations locations: [CLLocation])
  func locationManager(_ manager: CampusMapLocationManaging, didFailWithError error: Error)
}

protocol CampusMapLocationManaging: AnyObject {
  var locationDelegate: CampusMapLocationManagerDelegate? { get set }
  var desiredAccuracy: CLLocationAccuracy { get set }
  var distanceFilter: CLLocationDistance { get set }
  var activityType: CLActivityType { get set }
  var pausesLocationUpdatesAutomatically: Bool { get set }
  var authorizationStatus: CLAuthorizationStatus { get }
  var location: CLLocation? { get }

  func requestWhenInUseAuthorization()
  func requestLocation()
  func startUpdatingLocation()
  func stopUpdatingLocation()
}

private final class SystemCampusMapLocationManager: NSObject, CampusMapLocationManaging, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  weak var locationDelegate: CampusMapLocationManagerDelegate?

  override init() {
    super.init()
    manager.delegate = self
  }

  var desiredAccuracy: CLLocationAccuracy {
    get { manager.desiredAccuracy }
    set { manager.desiredAccuracy = newValue }
  }

  var distanceFilter: CLLocationDistance {
    get { manager.distanceFilter }
    set { manager.distanceFilter = newValue }
  }

  var activityType: CLActivityType {
    get { manager.activityType }
    set { manager.activityType = newValue }
  }

  var pausesLocationUpdatesAutomatically: Bool {
    get { manager.pausesLocationUpdatesAutomatically }
    set { manager.pausesLocationUpdatesAutomatically = newValue }
  }

  var authorizationStatus: CLAuthorizationStatus {
    manager.authorizationStatus
  }

  var location: CLLocation? {
    manager.location
  }

  func requestWhenInUseAuthorization() {
    manager.requestWhenInUseAuthorization()
  }

  func requestLocation() {
    manager.requestLocation()
  }

  func startUpdatingLocation() {
    manager.startUpdatingLocation()
  }

  func stopUpdatingLocation() {
    manager.stopUpdatingLocation()
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    locationDelegate?.locationManagerDidChangeAuthorization(self)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    locationDelegate?.locationManager(self, didUpdateLocations: locations)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    locationDelegate?.locationManager(self, didFailWithError: error)
  }
}

/// Foreground-only CoreLocation bridge for the campus map.
/// Uses when-in-use authorization exclusively and separates one-shot locate from
/// continuous watch updates so neither interferes with the other.
final class CampusMapLocationController: NSObject, CampusMapLocationManagerDelegate, FlutterStreamHandler {
  private final class PendingLocateRequest {
    private var completion: FlutterResult?
    var timeoutWorkItem: DispatchWorkItem?

    init(_ completion: @escaping FlutterResult) {
      self.completion = completion
    }

    func resolve(_ value: Any?) {
      timeoutWorkItem?.cancel()
      timeoutWorkItem = nil
      guard let completion else { return }
      self.completion = nil
      completion(value)
    }
  }

  private static let defaultLocateTimeoutSeconds: TimeInterval = 15
  private static let recentFixMaxAgeSeconds: TimeInterval = 5
  private static let recentFixMaxAccuracyMeters: CLLocationAccuracy = 65
  private static let activeAuthorizationRecheckDelay: TimeInterval = 0.25

  private let makeManager: () -> CampusMapLocationManaging
  private let checkServicesEnabled: (@escaping (Bool) -> Void) -> Void
  private let isAppActive: () -> Bool
  private let openAppSettings: (@escaping (Bool) -> Void) -> Void
  private let locateTimeoutSeconds: TimeInterval
  private let activeRecheckDelaySeconds: TimeInterval
  private let notificationCenter: NotificationCenter

  private var singleManagerStorage: CampusMapLocationManaging?
  private var watchManagerStorage: CampusMapLocationManaging?

  private var pendingAuthorizationRequests: [PendingLocateRequest] = []
  private var pendingLocateRequests: [PendingLocateRequest] = []
  private var isRequestingAuthorization = false
  private var isRequestingSingleLocation = false
  private var isWatching = false
  private var watchSessionID = 0
  private var eventSink: FlutterEventSink?
  private var activeRecheckWorkItem: DispatchWorkItem?
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    makeManager: @escaping () -> CampusMapLocationManaging = { SystemCampusMapLocationManager() },
    checkServicesEnabled: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
      DispatchQueue.global(qos: .userInitiated).async {
        let enabled = CLLocationManager.locationServicesEnabled()
        DispatchQueue.main.async {
          completion(enabled)
        }
      }
    },
    isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
    openAppSettings: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        completion(false)
        return
      }
      UIApplication.shared.open(url, options: [:], completionHandler: completion)
    },
    locateTimeoutSeconds: TimeInterval = CampusMapLocationController.defaultLocateTimeoutSeconds,
    activeRecheckDelaySeconds: TimeInterval = CampusMapLocationController.activeAuthorizationRecheckDelay,
    notificationCenter: NotificationCenter = .default
  ) {
    self.makeManager = makeManager
    self.checkServicesEnabled = checkServicesEnabled
    self.isAppActive = isAppActive
    self.openAppSettings = openAppSettings
    self.locateTimeoutSeconds = locateTimeoutSeconds
    self.activeRecheckDelaySeconds = activeRecheckDelaySeconds
    self.notificationCenter = notificationCenter
    super.init()

    lifecycleObservers = [
      notificationCenter.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleDidEnterBackground()
      },
      notificationCenter.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleDidBecomeActive()
      },
    ]
  }

  deinit {
    activeRecheckWorkItem?.cancel()
    for observer in lifecycleObservers {
      notificationCenter.removeObserver(observer)
    }
  }

  private func singleManager() -> CampusMapLocationManaging {
    if let existing = singleManagerStorage {
      return existing
    }
    let manager = makeManager()
    manager.locationDelegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .fitness
    manager.pausesLocationUpdatesAutomatically = true
    singleManagerStorage = manager
    return manager
  }

  private func watchManager() -> CampusMapLocationManaging {
    if let existing = watchManagerStorage {
      return existing
    }
    let manager = makeManager()
    manager.locationDelegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    manager.distanceFilter = 5
    manager.activityType = .fitness
    manager.pausesLocationUpdatesAutomatically = true
    watchManagerStorage = manager
    return manager
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "locate":
      locate(result: result)
    case "canWatch":
      canWatch(result: result)
    case "openSettings":
      openAppSettings(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - MethodChannel handlers

  private func locate(result: @escaping FlutterResult) {
    let request = PendingLocateRequest(result)
    checkServicesEnabled { [weak self] enabled in
      guard let self else {
        request.resolve(
          FlutterError(code: "location_unavailable", message: "Location controller released", details: nil)
        )
        return
      }
      guard enabled else {
        request.resolve(
          FlutterError(code: "location_services_disabled", message: "Location services disabled", details: nil)
        )
        return
      }

      let manager = self.singleManager()
      switch manager.authorizationStatus {
      case .authorizedWhenInUse, .authorizedAlways:
        self.requestSingleLocation(request)
      case .notDetermined:
        guard self.isAppActive() else {
          request.resolve(
            FlutterError(
              code: "location_unavailable",
              message: "App must be active to request location authorization",
              details: nil
            )
          )
          return
        }
        self.pendingAuthorizationRequests.append(request)
        if !self.isRequestingAuthorization {
          self.isRequestingAuthorization = true
          manager.requestWhenInUseAuthorization()
        }
      case .denied:
        request.resolve(
          FlutterError(code: "permission_denied_forever", message: "Location permission denied", details: nil)
        )
      case .restricted:
        request.resolve(
          FlutterError(code: "permission_denied", message: "Location permission restricted", details: nil)
        )
      @unknown default:
        request.resolve(
          FlutterError(code: "permission_denied", message: "Location permission unavailable", details: nil)
        )
      }
    }
  }

  private func canWatch(result: @escaping FlutterResult) {
    checkServicesEnabled { [weak self] enabled in
      guard let self, enabled else {
        result(false)
        return
      }
      result(self.isAuthorized(self.singleManager().authorizationStatus))
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    watchSessionID += 1
    let sessionID = watchSessionID
    eventSink = events
    isWatching = true

    checkServicesEnabled { [weak self] enabled in
      guard let self, self.isWatching, self.watchSessionID == sessionID else { return }
      guard enabled else {
        self.isWatching = false
        self.eventSink?(
          FlutterError(code: "location_services_disabled", message: "Location services disabled", details: nil)
        )
        return
      }
      let manager = self.watchManager()
      guard self.isAuthorized(manager.authorizationStatus) else {
        self.isWatching = false
        self.eventSink?(
          FlutterError(code: "permission_denied", message: "Location permission not granted", details: nil)
        )
        return
      }
      manager.startUpdatingLocation()
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    watchSessionID += 1
    isWatching = false
    eventSink = nil
    watchManagerStorage?.stopUpdatingLocation()
    return nil
  }

  // MARK: - App lifecycle safeguards

  private func handleDidEnterBackground() {
    activeRecheckWorkItem?.cancel()
    activeRecheckWorkItem = nil
    guard isRequestingAuthorization else { return }
    let status = singleManagerStorage?.authorizationStatus ?? .notDetermined
    guard status == .notDetermined else { return }
    isRequestingAuthorization = false
    failPendingAuthorizationRequests(
      FlutterError(
        code: "location_unavailable",
        message: "Location authorization interrupted by background transition",
        details: nil
      )
    )
  }

  private func handleDidBecomeActive() {
    guard isRequestingAuthorization else { return }
    activeRecheckWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isRequestingAuthorization else { return }
      let status = self.singleManagerStorage?.authorizationStatus ?? .notDetermined
      guard status == .notDetermined else { return }
      self.isRequestingAuthorization = false
      self.failPendingAuthorizationRequests(
        FlutterError(
          code: "location_unavailable",
          message: "Location authorization did not complete",
          details: nil
        )
      )
    }
    activeRecheckWorkItem = workItem
    if activeRecheckDelaySeconds <= 0 {
      workItem.perform()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + activeRecheckDelaySeconds, execute: workItem)
    }
  }

  // MARK: - CampusMapLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CampusMapLocationManaging) {
    let status = manager.authorizationStatus
    guard status != .notDetermined else { return }

    activeRecheckWorkItem?.cancel()
    activeRecheckWorkItem = nil
    isRequestingAuthorization = false

    let waiting = pendingAuthorizationRequests
    pendingAuthorizationRequests.removeAll()

    if isAuthorized(status) {
      for request in waiting {
        requestSingleLocation(request)
      }
      return
    }

    for request in waiting {
      request.resolve(
        FlutterError(code: "permission_denied", message: "Location permission denied", details: nil)
      )
    }

    let revokedCode = status == .denied ? "permission_denied_forever" : "permission_denied"
    if !pendingLocateRequests.isEmpty {
      isRequestingSingleLocation = false
      singleManagerStorage?.stopUpdatingLocation()
      failPendingLocateRequests(
        FlutterError(code: revokedCode, message: "Location permission denied", details: nil)
      )
    }
    if isWatching {
      isWatching = false
      watchManagerStorage?.stopUpdatingLocation()
      eventSink?(
        FlutterError(code: revokedCode, message: "Location permission revoked", details: nil)
      )
    }
  }

  func locationManager(_ manager: CampusMapLocationManaging, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last(where: isValidLocation) else { return }
    let payload = serialize(location)

    if manager === singleManagerStorage {
      if !pendingLocateRequests.isEmpty {
        isRequestingSingleLocation = false
        let requests = pendingLocateRequests
        pendingLocateRequests.removeAll()
        for request in requests {
          request.resolve(payload)
        }
      }
      return
    }

    if manager === watchManagerStorage {
      if isWatching {
        eventSink?(payload)
      }
      if !pendingLocateRequests.isEmpty {
        isRequestingSingleLocation = false
        let requests = pendingLocateRequests
        pendingLocateRequests.removeAll()
        for request in requests {
          request.resolve(payload)
        }
      }
    }
  }

  func locationManager(_ manager: CampusMapLocationManaging, didFailWithError error: Error) {
    let clError = error as? CLError
    if clError?.code == .denied {
      let code = manager.authorizationStatus == .restricted ? "permission_denied" : "permission_denied_forever"
      let flutterError = FlutterError(
        code: code,
        message: error.localizedDescription,
        details: nil
      )
      if manager === singleManagerStorage {
        isRequestingSingleLocation = false
        singleManagerStorage?.stopUpdatingLocation()
        failPendingLocateRequests(flutterError)
      }
      if manager === watchManagerStorage && isWatching {
        isWatching = false
        watchManagerStorage?.stopUpdatingLocation()
        eventSink?(flutterError)
      }
      return
    }

    if manager === watchManagerStorage {
      // Transient locationUnknown while continuously updating should keep listening.
      return
    }

    if manager === singleManagerStorage && !pendingLocateRequests.isEmpty {
      isRequestingSingleLocation = false
      failPendingLocateRequests(
        FlutterError(
          code: "location_unavailable",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  // MARK: - Helpers

  private func requestSingleLocation(_ request: PendingLocateRequest) {
    if let cached = latestFreshLocation() {
      request.resolve(serialize(cached))
      return
    }

    let timeout = DispatchWorkItem { [weak self, weak request] in
      guard let self, let request else { return }
      self.pendingLocateRequests.removeAll { $0 === request }
      if self.pendingLocateRequests.isEmpty {
        self.isRequestingSingleLocation = false
        self.singleManagerStorage?.stopUpdatingLocation()
      }
      request.resolve(
        FlutterError(code: "timeout", message: "Location request timed out", details: nil)
      )
    }
    request.timeoutWorkItem = timeout
    pendingLocateRequests.append(request)
    DispatchQueue.main.asyncAfter(deadline: .now() + locateTimeoutSeconds, execute: timeout)

    if !isRequestingSingleLocation {
      isRequestingSingleLocation = true
      singleManager().requestLocation()
    }
  }

  private func latestFreshLocation() -> CLLocation? {
    [singleManagerStorage?.location, watchManagerStorage?.location]
      .compactMap { $0 }
      .filter(isFreshEnough)
      .max { $0.timestamp < $1.timestamp }
  }

  private func failPendingAuthorizationRequests(_ error: FlutterError) {
    let requests = pendingAuthorizationRequests
    pendingAuthorizationRequests.removeAll()
    for request in requests {
      request.resolve(error)
    }
  }

  private func failPendingLocateRequests(_ error: FlutterError) {
    let requests = pendingLocateRequests
    pendingLocateRequests.removeAll()
    for request in requests {
      request.resolve(error)
    }
  }

  private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
    status == .authorizedWhenInUse || status == .authorizedAlways
  }

  private func isValidLocation(_ location: CLLocation) -> Bool {
    location.horizontalAccuracy >= 0 &&
      location.horizontalAccuracy.isFinite &&
      CLLocationCoordinate2DIsValid(location.coordinate)
  }

  private func isFreshEnough(_ location: CLLocation) -> Bool {
    isValidLocation(location) &&
      location.horizontalAccuracy <= Self.recentFixMaxAccuracyMeters &&
      abs(location.timestamp.timeIntervalSinceNow) <= Self.recentFixMaxAgeSeconds
  }

  private func serialize(_ location: CLLocation) -> [String: Double] {
    [
      "longitude": location.coordinate.longitude,
      "latitude": location.coordinate.latitude,
      "accuracy": location.horizontalAccuracy,
    ]
  }
}
