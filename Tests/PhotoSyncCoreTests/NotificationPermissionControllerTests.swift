import Foundation
import XCTest
@testable import PhotoSyncCore

@MainActor
final class NotificationPermissionControllerTests: XCTestCase {
    func testGrantedRequestClearsPriorAuthorizationWarning() async {
        let service = FakeNotificationPermissionService(authorization: false)
        let controller = makeController(preferenceEnabled: false, service: service)

        _ = await controller.refreshAuthorizationIfNeeded()
        XCTAssertNil(controller.state.warning)

        _ = controller.setPreferenceEnabled(true)
        service.requestAuthorizationResult = true
        _ = await controller.requestAuthorization()

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: true,
                systemAuthorized: true,
                warning: nil
            )
        )
        XCTAssertEqual(service.persistedPreference, true)
    }

    func testObservedSystemAuthorizationDoesNotEnableAppPreference() async {
        let service = FakeNotificationPermissionService(authorization: true)
        let controller = makeController(preferenceEnabled: false, service: service)

        _ = await controller.refreshAuthorizationIfNeeded()

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: false,
                systemAuthorized: true,
                warning: nil
            )
        )
        XCTAssertNil(service.persistedPreference)
    }

    func testRefreshAfterExternalAuthorizationClearsWarningWithoutChangingPreference() async {
        let service = FakeNotificationPermissionService(authorization: false)
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let controller = makeController(preferenceEnabled: true, service: service, clock: clock)

        _ = await controller.refreshAuthorizationIfNeeded()
        XCTAssertEqual(controller.state.warning, .authorizationDenied)

        service.authorization = true
        clock.now = clock.now.addingTimeInterval(30)
        _ = await controller.refreshAuthorizationIfNeeded()

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: true,
                systemAuthorized: true,
                warning: nil
            )
        )
    }

    func testDisablingClearsNotificationIssueWhenAuthorizationStatusCannotBeRead() async {
        let service = FakeNotificationPermissionService(authorization: false)
        service.statusError = NotificationPermissionTestError.temporaryFailure
        let controller = makeController(preferenceEnabled: true, service: service)

        _ = await controller.refreshAuthorizationIfNeeded()
        XCTAssertEqual(controller.state.warning, .authorizationStatusUnavailable("temporary failure"))

        _ = controller.setPreferenceEnabled(false)

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: false,
                systemAuthorized: nil,
                warning: nil
            )
        )
    }

    func testLateAuthorizationGrantCannotReenableDisabledPreference() async {
        let service = FakeNotificationPermissionService(authorization: false)
        let requestGate = AsyncGate()
        service.requestGate = requestGate
        let controller = makeController(preferenceEnabled: true, service: service)

        let completed = AsyncCompletion()
        Task { @MainActor in
            await controller.requestAuthorization()
            await completed.finish()
        }
        await requestGate.waitUntilStarted()

        _ = controller.setPreferenceEnabled(false)
        service.requestAuthorizationResult = true
        await requestGate.open()
        await completed.wait()

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: false,
                systemAuthorized: nil,
                warning: nil
            )
        )
    }

    func testLateStatusReadCannotOverwriteNewerAuthorizationRequest() async {
        let service = FakeNotificationPermissionService(authorization: false)
        let statusGate = AsyncGate()
        service.statusGate = statusGate
        let controller = makeController(preferenceEnabled: true, service: service)

        let completed = AsyncCompletion()
        Task { @MainActor in
            await controller.refreshAuthorizationIfNeeded()
            await completed.finish()
        }
        await statusGate.waitUntilStarted()

        service.requestAuthorizationResult = true
        _ = await controller.requestAuthorization()
        await statusGate.open()
        await completed.wait()

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: true,
                systemAuthorized: true,
                warning: nil
            )
        )
    }

    func testRefreshDoesNotSupersedeAnInFlightAuthorizationRequest() async {
        let service = FakeNotificationPermissionService(authorization: false)
        let requestGate = AsyncGate()
        service.requestGate = requestGate
        let controller = makeController(preferenceEnabled: true, service: service)

        let completed = AsyncCompletion()
        Task { @MainActor in
            await controller.requestAuthorization()
            await completed.finish()
        }
        await requestGate.waitUntilStarted()

        _ = await controller.refreshAuthorizationIfNeeded()
        service.requestAuthorizationResult = true
        await requestGate.open()
        await completed.wait()

        XCTAssertEqual(
            controller.state,
            NotificationPermissionState(
                preferenceEnabled: true,
                systemAuthorized: true,
                warning: nil
            )
        )
    }

    func testRefreshReadsSystemStatusAtMostOncePerThirtySeconds() async {
        let service = FakeNotificationPermissionService(authorization: true)
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let controller = makeController(preferenceEnabled: true, service: service, clock: clock)

        _ = await controller.refreshAuthorizationIfNeeded()
        _ = await controller.refreshAuthorizationIfNeeded()
        XCTAssertEqual(service.statusReadCount, 1)

        clock.now = clock.now.addingTimeInterval(29)
        _ = await controller.refreshAuthorizationIfNeeded()
        XCTAssertEqual(service.statusReadCount, 1)

        clock.now = clock.now.addingTimeInterval(1)
        _ = await controller.refreshAuthorizationIfNeeded()
        XCTAssertEqual(service.statusReadCount, 2)
    }

    private func makeController(
        preferenceEnabled: Bool,
        service: FakeNotificationPermissionService,
        clock: TestClock? = nil
    ) -> NotificationPermissionController {
        let resolvedClock = clock ?? TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        return NotificationPermissionController(
            preferenceEnabled: preferenceEnabled,
            now: { resolvedClock.now },
            readAuthorization: { try await service.readAuthorization() },
            requestAuthorization: { try await service.requestAuthorization() },
            persistPreference: { service.persistedPreference = $0 }
        )
    }
}

@MainActor
private final class TestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class FakeNotificationPermissionService {
    var authorization: Bool
    var requestAuthorizationResult = false
    var statusError: Error?
    var requestError: Error?
    var statusGate: AsyncGate?
    var requestGate: AsyncGate?
    var statusReadCount = 0
    var persistedPreference: Bool?

    init(authorization: Bool) {
        self.authorization = authorization
    }

    func readAuthorization() async throws -> Bool {
        statusReadCount += 1
        if let statusGate {
            await statusGate.wait()
        }
        if let statusError {
            throw statusError
        }
        return authorization
    }

    func requestAuthorization() async throws -> Bool {
        if let requestGate {
            await requestGate.wait()
        }
        if let requestError {
            throw requestError
        }
        return requestAuthorizationResult
    }
}

private enum NotificationPermissionTestError: LocalizedError {
    case temporaryFailure

    var errorDescription: String? {
        switch self {
        case .temporaryFailure:
            return "temporary failure"
        }
    }
}

private actor AsyncGate {
    private var opened = false
    private var started = false
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func open() {
        opened = true
        waitContinuation?.resume()
        waitContinuation = nil
    }
}

private actor AsyncCompletion {
    private var completed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        completed = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !completed else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
