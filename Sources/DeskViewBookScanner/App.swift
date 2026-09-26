import SwiftUI
import BookScannerKit

@main
struct DeskViewBookScannerApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(model)
        } label: {
            Image(systemName: "book.pages")
        }
        .menuBarExtraStyle(.window)

        Window(L("Session"), id: "session") {
            SessionWindow().environment(model)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView().environment(model)
        }
    }
}
