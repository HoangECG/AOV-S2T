import SwiftUI

@main
struct MacSpeechTranslatorApp: App {
    @StateObject private var appState: AppState

    init() {
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        WindowGroup("MacSpeechTranslator") {
            MainView(appState: appState)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .defaultSize(width: 1_260, height: 780)
    }
}
