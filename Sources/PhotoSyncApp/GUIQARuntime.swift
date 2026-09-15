#if GUI_QA
import Foundation
import PhotoSyncCore

enum GUIQARuntimeFactory {
    static func make(
        configuration: GUIQALaunchConfiguration,
        productionSupportDirectory: URL
    ) throws -> SyncRuntime {
        let paths = try GUIQADataPaths.create(
            root: configuration.root,
            productionSupportDirectory: productionSupportDirectory
        )
        let store = try SyncStore(url: paths.databaseURL)
        let logger = try RunLogger(directory: paths.logsURL)
        switch configuration.mode {
        case .fake:
            let gateway = GUIQAFakePhotosGateway()
            let engine = SyncEngine(store: store, photos: gateway, logger: logger)
            return SyncRuntime(
                store: store,
                engine: engine,
                logsURL: paths.logsURL,
                databaseURL: paths.databaseURL,
                now: { Date() },
                authorized: { true },
                requestAuthorization: { true },
                notificationsEnabled: { false }
            )
        case .readonly:
            let gateway = GUIQAReadOnlyPhotosGateway()
            let engine = SyncEngine(store: store, photos: gateway, logger: logger)
            return SyncRuntime(
                store: store,
                engine: engine,
                logsURL: paths.logsURL,
                databaseURL: paths.databaseURL,
                now: { Date() },
                authorized: { gateway.isAuthorized },
                requestAuthorization: { await gateway.requestAuthorization() },
                notificationsEnabled: { false }
            )
        }
    }
}

private actor GUIQAFakePhotosGateway: PhotosGateway {
    private var submissionCount = 0

    func loadCandidates() async throws -> [MatchCandidate] { [] }

    func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        submissionCount += 1
        let identifier = "guiqa-fake-\(submissionCount)"
        try onPlaceholder(identifier)
        try await Task.sleep(for: .seconds(1))
        return identifier
    }

    func reconcile(placeholder: String?) async throws -> ImportEvidence {
        guard let placeholder, placeholder.hasPrefix("guiqa-fake-") else { return .unknown }
        return .found(identifier: placeholder)
    }
}
#endif
