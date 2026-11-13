import SwiftUI

@main
struct TecladoVozApp: App {
    @StateObject private var engine = DictationEngine.shared
    @State private var showReturnHint = false

    var body: some Scene {
        WindowGroup {
            ContentView(showReturnHint: $showReturnHint)
                .environmentObject(engine)
                .onOpenURL { url in
                    guard url.scheme == Shared.urlScheme else { return }
                    if url.host == "dictate" {
                        engine.requestPermissions { engine.startDictation() }
                    } else {
                        engine.requestPermissions { engine.startSession() }
                    }
                    showReturnHint = true
                }
        }
    }
}
