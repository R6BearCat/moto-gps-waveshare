import CoreLocation
import MotoNavigationCore

@MainActor
final class CoreLocationNavigationSource: NSObject, NavigationLocationSource {
    private static let maximumFixAgeS: TimeInterval = 5
    var onDiagnostic: ((String) -> Void)?
    private var lastCallbackUptime: TimeInterval?
    private var lastAcceptedTimestamp: Date?
    private let manager = CLLocationManager()
    private var onFix: (@MainActor (NavigationFix) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Keep fixes flowing even while the bike is parked: with a 2 m
        // distance filter Core Location stops reporting when the rider
        // stands still, leaving the last non-zero speed frozen on the
        // handlebar gauge. kCLDistanceFilterNone keeps ~1 Hz updates so
        // the speed decays to zero within a couple of seconds.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        #if os(iOS)
        manager.showsBackgroundLocationIndicator = true
        #endif
    }

    func start(
        onFix: @escaping @MainActor (NavigationFix) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        self.onFix = onFix
        self.onFailure = onFailure
        wantsUpdates = true
        lastAcceptedTimestamp = nil
        lastCallbackUptime = nil
        onDiagnostic?("start auth=\(manager.authorizationStatus.rawValue) accuracyAuth=\(manager.accuracyAuthorization.rawValue)")

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
        case .restricted, .denied:
            throw NavigationSourceError.permissionDenied
        @unknown default:
            throw NavigationSourceError.unavailable("当前系统无法确认定位权限")
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        onFix = nil
        onFailure = nil
    }
}

extension CoreLocationNavigationSource: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsUpdates else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .restricted, .denied:
            onFailure?("定位权限已关闭，请在系统设置中允许“始终”定位")
        case .notDetermined:
            break
        @unknown default:
            onFailure?("当前系统无法确认定位权限")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wantsUpdates else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let gap = lastCallbackUptime.map { uptime - $0 } ?? -1
        lastCallbackUptime = uptime
        if let newest = locations.max(by: { $0.timestamp < $1.timestamp }) {
            onDiagnostic?("callback count=\(locations.count) gap_s=\(gap) age_s=\(now.timeIntervalSince(newest.timestamp)) accuracy_m=\(newest.horizontalAccuracy) duplicate=\(lastAcceptedTimestamp.map { newest.timestamp <= $0 } ?? false)")
        }
        guard let location = locations
            .filter({
                $0.horizontalAccuracy >= 0 &&
                    $0.coordinate.latitude.isFinite &&
                    $0.coordinate.longitude.isFinite &&
                    now.timeIntervalSince($0.timestamp) >= 0 &&
                    now.timeIntervalSince($0.timestamp) <= Self.maximumFixAgeS
            })
            .max(by: { $0.timestamp < $1.timestamp })
        else { onDiagnostic?("reject invalid or older-than-5s fix"); return }
        if let lastAcceptedTimestamp, location.timestamp <= lastAcceptedTimestamp {
            onDiagnostic?("reject duplicate or out-of-order fix")
            return
        }
        lastAcceptedTimestamp = location.timestamp
        onDiagnostic?("accept age_s=\(now.timeIntervalSince(location.timestamp))")

        onFix?(
            NavigationFix(
                coordinate: WGS84Point(
                    longitudeDeg: location.coordinate.longitude,
                    latitudeDeg: location.coordinate.latitude
                ),
                altitudeM: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracyM: location.horizontalAccuracy,
                speedMps: location.speed >= 0 ? location.speed : nil,
                courseDeg: location.course >= 0 ? location.course : nil,
                timestamp: location.timestamp
            )
        )
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        onDiagnostic?("system paused location updates")
        if wantsUpdates { manager.startUpdatingLocation() }
    }
    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        onDiagnostic?("system resumed location updates")
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onDiagnostic?("location error code=\((error as NSError).code)")
        let locationError = error as? CLError
        if locationError?.code == .locationUnknown { return }
        onFailure?(error.localizedDescription)
    }
}
