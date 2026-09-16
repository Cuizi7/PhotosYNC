import Foundation

public enum NotificationPermissionWarning: Equatable, Sendable {
    case authorizationDenied
    case authorizationStatusUnavailable(String)
    case authorizationRequestFailed(String)
}

public struct NotificationPermissionState: Equatable, Sendable {
    public var preferenceEnabled: Bool
    public var systemAuthorized: Bool?
    public var warning: NotificationPermissionWarning?

    public init(
        preferenceEnabled: Bool,
        systemAuthorized: Bool? = nil,
        warning: NotificationPermissionWarning? = nil
    ) {
        self.preferenceEnabled = preferenceEnabled
        self.systemAuthorized = systemAuthorized
        self.warning = warning
    }
}

/// Keeps the app's notification preference separate from the system permission.
@MainActor
public final class NotificationPermissionController {
    public private(set) var state: NotificationPermissionState

    private let now: @MainActor () -> Date
    private let readAuthorization: @MainActor () async throws -> Bool
    private let requestAuthorization: @MainActor () async throws -> Bool
    private let persistPreference: @MainActor (Bool) -> Void
    private let refreshInterval: TimeInterval
    private var lastAuthorizationRefreshAt: Date?
    private var revision = UInt64.zero
    private var authorizationRequestRevision: UInt64?

    public init(
        preferenceEnabled: Bool,
        refreshInterval: TimeInterval = 30,
        now: @escaping @MainActor () -> Date = { Date() },
        readAuthorization: @escaping @MainActor () async throws -> Bool,
        requestAuthorization: @escaping @MainActor () async throws -> Bool,
        persistPreference: @escaping @MainActor (Bool) -> Void
    ) {
        state = NotificationPermissionState(preferenceEnabled: preferenceEnabled)
        self.refreshInterval = refreshInterval
        self.now = now
        self.readAuthorization = readAuthorization
        self.requestAuthorization = requestAuthorization
        self.persistPreference = persistPreference
    }

    @discardableResult
    public func setPreferenceEnabled(_ enabled: Bool) -> NotificationPermissionState {
        revision &+= 1
        authorizationRequestRevision = nil
        state.preferenceEnabled = enabled
        persistPreference(enabled)
        state.warning = warning(for: state.systemAuthorized)
        return state
    }

    /// Reads the current system setting without requesting authorization.
    @discardableResult
    public func refreshAuthorizationIfNeeded() async -> NotificationPermissionState {
        guard authorizationRequestRevision == nil else { return state }

        let refreshStartedAt = now()
        if let lastAuthorizationRefreshAt,
           refreshStartedAt.timeIntervalSince(lastAuthorizationRefreshAt) < refreshInterval {
            return state
        }

        lastAuthorizationRefreshAt = refreshStartedAt
        let requestRevision = nextRevision()
        do {
            let authorized = try await readAuthorization()
            guard requestRevision == revision else { return state }
            state.systemAuthorized = authorized
            state.warning = warning(for: authorized)
        } catch {
            guard requestRevision == revision else { return state }
            state.warning = state.preferenceEnabled
                ? .authorizationStatusUnavailable(error.localizedDescription)
                : nil
        }
        return state
    }

    @discardableResult
    public func requestAuthorization() async -> NotificationPermissionState {
        guard state.preferenceEnabled else { return state }

        let requestRevision = nextRevision()
        authorizationRequestRevision = requestRevision
        defer {
            if authorizationRequestRevision == requestRevision {
                authorizationRequestRevision = nil
            }
        }
        do {
            let authorized = try await requestAuthorization()
            guard requestRevision == revision, state.preferenceEnabled else { return state }
            state.systemAuthorized = authorized
            state.warning = warning(for: authorized)
            lastAuthorizationRefreshAt = now()
        } catch {
            guard requestRevision == revision, state.preferenceEnabled else { return state }
            state.warning = .authorizationRequestFailed(error.localizedDescription)
        }
        return state
    }

    private func warning(for systemAuthorized: Bool?) -> NotificationPermissionWarning? {
        guard state.preferenceEnabled, systemAuthorized == false else { return nil }
        return .authorizationDenied
    }

    private func nextRevision() -> UInt64 {
        revision &+= 1
        return revision
    }
}
