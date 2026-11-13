import Foundation

struct Replacement: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var from: String
    var to: String
}

struct KeyboardSettings: Codable, Equatable {
    var keyHeight: Double = 54
    var keySpacing: Double = 6
    var fontSize: Double = 23
    var haptics: Bool = true
    var clicks: Bool = true
    var preferOffline: Bool = true
    var sessionMinutes: Double = 10
    var autocorrect: Bool = true
    var swipeTyping: Bool = true
    var modernDictation: Bool = true
    var aiPunctuation: Bool = true
    var vocabulary: [String] = KeyboardSettings.defaultVocabulary
    var replacements: [Replacement] = KeyboardSettings.defaultReplacements

    enum CodingKeys: String, CodingKey {
        case keyHeight, keySpacing, fontSize, haptics, clicks, preferOffline,
             sessionMinutes, autocorrect, swipeTyping, modernDictation, aiPunctuation, vocabulary, replacements
    }

    init() {}

    // Decodificação tolerante: campos novos em versões futuras não apagam os ajustes
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyboardSettings()
        keyHeight = try c.decodeIfPresent(Double.self, forKey: .keyHeight) ?? d.keyHeight
        keySpacing = try c.decodeIfPresent(Double.self, forKey: .keySpacing) ?? d.keySpacing
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        clicks = try c.decodeIfPresent(Bool.self, forKey: .clicks) ?? d.clicks
        preferOffline = try c.decodeIfPresent(Bool.self, forKey: .preferOffline) ?? d.preferOffline
        sessionMinutes = try c.decodeIfPresent(Double.self, forKey: .sessionMinutes) ?? d.sessionMinutes
        autocorrect = try c.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? d.autocorrect
        swipeTyping = try c.decodeIfPresent(Bool.self, forKey: .swipeTyping) ?? d.swipeTyping
        modernDictation = try c.decodeIfPresent(Bool.self, forKey: .modernDictation) ?? d.modernDictation
        aiPunctuation = try c.decodeIfPresent(Bool.self, forKey: .aiPunctuation) ?? d.aiPunctuation
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
    }

    static func load() -> KeyboardSettings {
        guard let data = Shared.defaults?.data(forKey: K.settings),
              let s = try? JSONDecoder().decode(KeyboardSettings.self, from: data) else {
            return KeyboardSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Shared.defaults?.set(data, forKey: K.settings)
        }
        DarwinNote.post(DarwinNote.settings)
    }

    static let defaultVocabulary: [String] = [
        "pickup", "dropout", "trip", "dial", "TC", "TP", "IEC", "ANSI",
        "50N", "51N", "67N", "Conprove", "CE-6710", "religador", "disjuntor",
        "seccionadora", "SEL", "Schneider", "Siemens", "subestação"
    ]

    static let defaultReplacements: [Replacement] = [
        Replacement(from: "ponto e vírgula", to: ";"),
        Replacement(from: "ponto final", to: "."),
        Replacement(from: "ponto de interrogação", to: "?"),
        Replacement(from: "ponto de exclamação", to: "!"),
        Replacement(from: "dois pontos", to: ":"),
        Replacement(from: "vírgula", to: ","),
        Replacement(from: "nova linha", to: "\\n"),
        Replacement(from: "novo parágrafo", to: "\\n\\n"),
        Replacement(from: "pick up", to: "pickup"),
        Replacement(from: "pick-up", to: "pickup"),
        Replacement(from: "drop out", to: "dropout")
    ]
}

enum TextProcessor {
    static func process(_ raw: String, settings: KeyboardSettings) -> String {
        var out = raw
        let reps = settings.replacements
            .filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.from.count > $1.from.count }
        for r in reps {
            let from = NSRegularExpression.escapedPattern(for: r.from.trimmingCharacters(in: .whitespaces))
            let pattern = "(?<![\\p{L}\\p{N}])" + from + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let to = NSRegularExpression.escapedTemplate(for: r.to.replacingOccurrences(of: "\\n", with: "\n"))
            out = re.stringByReplacingMatches(in: out, options: [],
                                              range: NSRange(out.startIndex..., in: out), withTemplate: to)
        }
        // Limpezas: espaço antes de pontuação, pontuação repetida, espaços ao redor de quebras
        out = out.replacingOccurrences(of: "[ \\t]+([,.;:!?])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "([,;:])\\1+", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "[,;:]([.!?])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        out = capitalizeSentences(out)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Letra maiúscula depois de . ! ? ou quebra de linha (dentro do texto ditado)
    private static func capitalizeSentences(_ s: String) -> String {
        var result = ""
        var capNext = false
        for ch in s {
            if capNext && ch.isLetter {
                result += ch.uppercased()
                capNext = false
                continue
            }
            if ".!?\n".contains(ch) { capNext = true }
            else if !ch.isWhitespace { capNext = false }
            result.append(ch)
        }
        return result
    }
}
