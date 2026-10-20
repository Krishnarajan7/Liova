import CoreLocation
import Foundation
import os

/// Where the Mac roughly is, for weather. Behind a protocol so features are tested without
/// Location Services.
@MainActor
public protocol ApproximateLocating: AnyObject {
    var authorization: LocationAuthorization { get }
    /// Asks macOS for permission if it hasn't been asked; calls back when the answer changes.
    func requestAuthorization(onChange: @escaping @MainActor (LocationAuthorization) -> Void)
    /// One reading, coarse. Throws when unavailable or not allowed.
    func currentLocation() async throws -> ApproximatePlace
}

/// Roughly where the Mac is, and what the place is called when known.
public struct ApproximatePlace: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}

public enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// Core Location at reduced accuracy (a few kilometres), one reading at a time: no
/// continuous tracking, so nothing runs between weather refreshes. The place name comes
/// from Apple's reverse geocoder.
@MainActor
public final class CoreLocationApproximateLocation: ApproximateLocating {
    private let manager = CLLocationManager()
    /// Owned here: the manager holds its delegate weakly.
    private let callbacks = Delegate()
    private let geocoder = CLGeocoder()
    private var onAuthorizationChange: (@MainActor (LocationAuthorization) -> Void)?
    private var pending: [CheckedContinuation<CLLocation, any Error>] = []
    public init() {
        callbacks.onAuthorization = { [weak self] status in self?.onAuthorizationChange?(status) }
        callbacks.onResult = { [weak self] result in self?.finish(result) }
        manager.delegate = callbacks
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    public var authorization: LocationAuthorization {
        Self.map(manager.authorizationStatus)
    }

    public func requestAuthorization(onChange: @escaping @MainActor (LocationAuthorization) -> Void) {
        onAuthorizationChange = onChange
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            onChange(authorization)
        }
    }

    public func currentLocation() async throws -> ApproximatePlace {
        guard authorization == .authorized else { throw CLError(.denied) }
        let location = try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            if pending.count == 1 {
                manager.requestLocation()
            }
        }
        let name = try? await geocoder.reverseGeocodeLocation(location).first.flatMap { $0.locality ?? $0.name }
        return ApproximatePlace(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            name: name
        )
    }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        default: .denied
        }
    }

    private func finish(_ result: Result<CLLocation, any Error>) {
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume(with: result) }
    }
}

/// Receives Core Location's callbacks, on the main thread where the manager was made, and
/// hands them to the main actor.
@MainActor
private final class Delegate: NSObject, CLLocationManagerDelegate {
    var onAuthorization: ((LocationAuthorization) -> Void)?
    var onResult: ((Result<CLLocation, any Error>) -> Void)?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = CoreLocationApproximateLocation.map(manager.authorizationStatus)
        MainActor.assumeIsolated { onAuthorization?(status) }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { onResult?(.success(location)) }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
        locationLog.notice("Location unavailable")
        MainActor.assumeIsolated { onResult?(.failure(error)) }
    }
}

private let locationLog = Logger(subsystem: "app.liova.Liova", category: "weather")
