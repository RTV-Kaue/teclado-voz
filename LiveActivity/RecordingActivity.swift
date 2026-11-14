import Foundation
import ActivityKit
import AppIntents

/// Dados da Live Activity (tela bloqueada e Dynamic Island)
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "pronto", "gravando", "online" (transcrevendo na internet), "local" (processando no iPhone)
        var phase: String
        var since: Date
    }
}

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName(name as CFString), nil, nil, true)
}

/// Botão "Parar" (encerra a gravação; o texto entra quando você voltar ao teclado)
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Parar gravação"
    func perform() async throws -> some IntentResult {
        postDarwin("com.kaue.tecladovoz.stop")
        return .result()
    }
}

/// Botão "Encerrar" (desliga o microfone e a sessão, economiza bateria)
struct EndSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Encerrar sessão"
    func perform() async throws -> some IntentResult {
        postDarwin("com.kaue.tecladovoz.endsession")
        return .result()
    }
}
