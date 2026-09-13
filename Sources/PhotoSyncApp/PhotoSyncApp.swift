import SwiftUI

@main
struct PhotoSyncApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(systemName: model.status.symbol).accessibilityLabel(model.statusDescription)
        }.menuBarExtraStyle(.window)
        Settings { SourceSettings(model: model) }

    }
}
