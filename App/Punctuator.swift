import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Coloca pontuação no texto ditado.
/// 1º tenta a IA que roda dentro do iPhone (Apple Intelligence, gratuita e offline);
/// se não houver, usa regras simples (maiúscula no início, ponto ou interrogação no fim).
enum Punctuator {

    static var aiStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "disponível"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "este iPhone não suporta"
                case .appleIntelligenceNotEnabled: return "ative a Apple Intelligence nos Ajustes"
                case .modelNotReady: return "modelo ainda baixando"
                @unknown default: return "indisponível"
                }
            }
        }
        #endif
        return "requer iOS 26"
    }

    static var aiAvailable: Bool { aiStatus == "disponível" }

    /// Pontua com a IA. Devolve nil se não der (indisponível, demorou demais, ou mudou palavras).
    static func punctuateWithAI(_ text: String, timeout: Double = 6) async -> String? {
        guard aiAvailable else { return nil }
        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await askModel(text) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
        guard let result, sameWords(result, text) else { return nil }
        return result
    }

    private static func askModel(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
            Você recebe um texto ditado em português do Brasil, com pouca ou nenhuma pontuação. \
            Devolva exatamente as mesmas palavras, na mesma ordem, apenas acrescentando pontuação \
            (vírgulas, pontos, ponto de interrogação, ponto de exclamação) e letras maiúsculas onde for correto. \
            Não troque, não corrija, não remova e não acrescente palavras. Responda somente com o texto pontuado.
            """)
            do {
                let r = try await session.respond(to: text, options: GenerationOptions(temperature: 0))
                return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Garante que a IA não mudou nenhuma palavra
    static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        }
        return words(a) == words(b)
    }

    static func hasPunctuation(_ s: String) -> Bool {
        s.contains { ".,!?;:".contains($0) }
    }

    /// Regras simples para quando não há IA
    static func heuristic(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if !hasPunctuation(t) {
            for w in ["mas", "porém", "contudo", "entretanto", "todavia"] {
                t = t.replacingOccurrences(of: " \(w) ", with: ", \(w) ")
            }
        }
        t = t.prefix(1).uppercased() + t.dropFirst()
        if let last = t.last, !".!?…:;".contains(last) {
            let lower = t.lowercased()
            let questionStarts = ["que ", "qual ", "quais ", "quando ", "onde ", "como ", "quem ", "quanto ",
                                  "quanta ", "quantos ", "quantas ", "será ", "cadê ", "por que ", "o que ",
                                  "pra que ", "para que "]
            t += questionStarts.contains(where: { lower.hasPrefix($0) }) ? "?" : "."
        }
        return t
    }
}
