import Foundation

// Chaves usadas no armazenamento compartilhado entre o app e o teclado
enum K {
    static let settings = "settings.v1"
    static let heartbeat = "session.heartbeat"
    static let recording = "session.recording"
    static let partial = "session.partial"
    static let status = "session.status"
    static let result = "result.text"
    static let resultID = "result.id"
    static let resultTime = "result.time"
    static let consumedID = "result.consumed"
    static let learned = "learned.words"
    static let needsAI = "result.needsAI"
    static let diagPunct = "diag.punct"
    static let blocked = "blocked.words"
    static let phase = "session.phase"        // gravando / online / local / ""
    static let lastSource = "result.source"   // online / ai / rules
}

enum Shared {
    static let baseGroup = "group.com.kaue.tecladovoz"
    static let urlScheme = "tecladovoz"

    /// Descobre o App Group real. O SideStore costuma renomear o grupo
    /// (acrescentando o Team ID), então testamos várias possibilidades.
    static let appGroupID: String? = {
        var candidates: [String] = []
        var mainInfo = Bundle.main.infoDictionary
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "appex" {
            // Estamos no teclado: o app principal fica duas pastas acima
            let appURL = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let appBundle = Bundle(url: appURL) {
                if let g = appBundle.infoDictionary?["ALTAppGroups"] as? [String] { candidates += g }
                mainInfo = appBundle.infoDictionary
            }
        }
        if let g = Bundle.main.infoDictionary?["ALTAppGroups"] as? [String] { candidates += g }
        if let mainID = mainInfo?["CFBundleIdentifier"] as? String { candidates.append("group." + mainID) }
        candidates.append(baseGroup)
        for g in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) != nil {
            return g
        }
        return nil
    }()

    static let defaults: UserDefaults? = appGroupID.flatMap { UserDefaults(suiteName: $0) }

    /// A sessão está viva se o app atualizou o "batimento" nos últimos segundos
    static var sessionAlive: Bool {
        guard let d = defaults else { return false }
        return Date().timeIntervalSince1970 - d.double(forKey: K.heartbeat) < 3.5
    }
}

// MARK: - Notificações entre processos (app <-> teclado)

enum DarwinNote {
    static let start = "com.kaue.tecladovoz.start"
    static let stop = "com.kaue.tecladovoz.stop"
    static let cancel = "com.kaue.tecladovoz.cancel"
    static let state = "com.kaue.tecladovoz.state"
    static let result = "com.kaue.tecladovoz.result"
    static let settings = "com.kaue.tecladovoz.settings"
    static let endSession = "com.kaue.tecladovoz.endsession"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

final class DarwinObserver {
    private var handlers: [String: () -> Void] = [:]

    func observe(_ name: String, _ handler: @escaping () -> Void) {
        handlers[name] = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { me.handlers[key]?() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }
}
