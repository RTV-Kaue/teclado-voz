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
                    let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "host" })?.value
                    let goBack = {
                        // Volta sozinho para o app onde a pessoa estava (WhatsApp etc.)
                        guard let host, engine.sessionActive else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if ReturnToHost.open(bundleID: host) { showReturnHint = false }
                        }
                    }
                    showReturnHint = true
                    if url.host == "dictate" {
                        engine.requestPermissions { engine.startDictation(); goBack() }
                    } else {
                        engine.requestPermissions { engine.startSession(); goBack() }
                    }
                }
        }
    }
}
