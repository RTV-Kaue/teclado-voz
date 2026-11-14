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

    private static let instructions = """
    Você recebe um texto ditado em português do Brasil, com pouca ou nenhuma pontuação. \
    Reescreva exatamente as mesmas palavras, na mesma ordem, apenas acrescentando pontuação \
    (vírgulas, pontos, ponto de interrogação, ponto de exclamação) e letras maiúsculas onde for correto. \
    Não troque, não corrija, não remova e não acrescente palavras. Não escreva números por extenso nem em algarismos de forma diferente. \
    Regras: use ponto de interrogação em perguntas (inclusive "tudo bem", "né", "certo", "pode ser" no fim de frase \
    e perguntas sem palavra interrogativa, como "você vem amanhã"); use vírgula depois de saudações e vocativos \
    ("oi, João"), antes de "mas", "porém", "então" e "porque" quando ligam frases, e para separar itens de listas; \
    termine cada frase com ponto. Responda somente com o texto pontuado, sem aspas e sem comentários.

    Exemplos:
    Entrada: oi tudo bem você vem amanhã eu chego às oito mas não sei se vou atrasar
    Saída: Oi, tudo bem? Você vem amanhã? Eu chego às oito, mas não sei se vou atrasar.
    Entrada: bom dia pessoal hoje vamos testar o relé de sobrecorrente e depois o diferencial alguém tem dúvida
    Saída: Bom dia, pessoal. Hoje vamos testar o relé de sobrecorrente e depois o diferencial. Alguém tem dúvida?
    Entrada: preciso comprar arroz feijão leite e pão pode ser
    Saída: Preciso comprar arroz, feijão, leite e pão. Pode ser?
    """

    // Sessão preparada com antecedência (carrega o modelo enquanto a pessoa fala)
    private static var prepared: AnyObject?

    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard aiAvailable, prepared == nil else { return }
            let s = LanguageModelSession(instructions: instructions)
            s.prewarm()
            prepared = s
        }
        #endif
    }

    /// Pontua com a IA. Devolve o texto (ou nil) e uma explicação para o diagnóstico.
    static func punctuateWithAI(_ text: String, timeout: Double = 10) async -> (String?, String) {
        guard aiAvailable else { return (nil, "IA indisponível: \(aiStatus)") }
        let answer: (String?, String) = await withTaskGroup(of: (String?, String).self) { group in
            group.addTask { await askModel(text) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return (nil, "IA demorou mais de \(Int(timeout))s")
            }
            let first = await group.next() ?? (nil, "sem resposta")
            group.cancelAll()
            return first
        }
        guard let ai = answer.0 else { return answer }
        guard let merged = transferPunctuation(original: text, ai: ai) else {
            return (nil, "IA não pontuou ou mudou palavras: \(ai.prefix(80))")
        }
        return (merged, "IA do iPhone")
    }

    private static func askModel(_ text: String) async -> (String?, String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = (prepared as? LanguageModelSession) ?? LanguageModelSession(instructions: instructions)
            prepared = nil
            do {
                let r = try await session.respond(to: text, options: GenerationOptions(temperature: 0))
                return (r.content.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            } catch {
                return (nil, "erro da IA: \(error.localizedDescription)")
            }
        }
        #endif
        return (nil, "requer iOS 26")
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Copia só a pontuação e as maiúsculas da resposta da IA para as palavras originais.
    /// Assim a IA nunca troca uma palavra do que foi falado.
    static func transferPunctuation(original: String, ai: String) -> String? {
        struct Tok { let key: String; let upper: Bool; let trail: String }
        let punct = Set(".,!?;:…")
        var toks: [Tok] = []
        for chunk in ai.split(whereSeparator: { $0.isWhitespace }) {
            var core = String(chunk)
            var trail = ""
            while let last = core.last, punct.contains(last) {
                trail = String(last) + trail
                core.removeLast()
            }
            let key = fold(core)
            if key.isEmpty {
                // pontuação solta: junta no anterior
                if !toks.isEmpty {
                    let t = toks.removeLast()
                    toks.append(Tok(key: t.key, upper: t.upper, trail: t.trail + trail))
                }
                continue
            }
            let firstLetter = core.first(where: { $0.isLetter })
            toks.append(Tok(key: key, upper: firstLetter?.isUppercase ?? false, trail: trail))
        }

        let words = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, !toks.isEmpty else { return nil }
        var out: [String] = []
        var j = 0
        var matched = 0
        var sentenceStart = true
        for w0 in words {
            let w = w0
            defer {
                if let last = out.last?.last { sentenceStart = ".!?…".contains(last) }
            }
            let k = fold(w)
            var word = w
            for look in 0..<3 where j + look < toks.count {
                if toks[j + look].key == k {
                    let t = toks[j + look]
                    j += look + 1
                    matched += 1
                    // maiúscula só no começo de frase (a IA às vezes capitaliza à toa)
                    if sentenceStart, let f = word.first, f.isLowercase {
                        word = word.prefix(1).uppercased() + word.dropFirst()
                    } else if !sentenceStart, !t.upper, word.count > 1,
                              let f = word.first, f.isUppercase, word.dropFirst().first?.isLowercase == true {
                        word = word.prefix(1).lowercased() + word.dropFirst()
                    }
                    if !t.trail.isEmpty, let last = word.last, !punct.contains(last) {
                        word += t.trail
                    }
                    break
                }
            }
            out.append(word)
        }
        guard Double(matched) >= Double(words.count) * 0.7 else { return nil }
        let result = out.joined(separator: " ")
        guard hasPunctuation(result) else { return nil }
        return result
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
