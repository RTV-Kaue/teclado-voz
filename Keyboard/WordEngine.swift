import Foundation

/// Dicionário de português com frequência de uso.
/// Usado para correção automática, sugestões e digitação deslizando.
final class WordEngine {
    static let shared = WordEngine()

    private(set) var loaded = false
    private var loading = false
    private var freq: [String: Int] = [:]              // palavra minúscula -> frequência
    private var bestByKey: [String: String] = [:]      // sem acento -> palavra mais usada
    private var sortedKeys: [String] = []              // chaves sem acento, em ordem alfabética
    private var sortedWords: [String] = []
    private var swipeIndex: [String: [String]] = [:]   // primeira+última letra -> palavras
    private var protected: Set<String> = []            // vocabulário técnico + palavras aprendidas
    private let queue = DispatchQueue(label: "WordEngine", qos: .userInitiated)

    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    // MARK: Carregamento

    func load(extra: [String], learned: [String], completion: @escaping () -> Void) {
        if loaded {
            setProtected(extra: extra, learned: learned)
            completion()
            return
        }
        guard !loading else { return }
        loading = true
        queue.async {
            var f: [String: Int] = [:]
            if let url = Bundle.main.url(forResource: "palavras", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                text.enumerateLines { line, _ in
                    let parts = line.split(separator: " ")
                    guard parts.count >= 2, let n = Int(parts[1]) else { return }
                    let w = String(parts[0]).lowercased()
                    guard w.allSatisfy({ $0.isLetter || $0 == "-" }) else { return }
                    if w.count == 1 && !["a", "e", "o", "é", "à", "ó", "ô"].contains(w) { return }
                    f[w] = max(f[w] ?? 0, n)
                }
            }
            // Vocabulário técnico entra como palavra bem frequente
            let topFreq = f.values.max() ?? 1000
            for t in extra where !t.isEmpty {
                let w = t.lowercased()
                f[w] = max(f[w] ?? 0, topFreq / 50)
            }
            for t in learned where !t.isEmpty {
                let w = t.lowercased()
                f[w] = max(f[w] ?? 0, topFreq / 200)
            }

            let ordered = f.sorted { $0.value > $1.value }
            var best: [String: String] = [:]
            var swipe: [String: [String]] = [:]
            var pairs: [(String, String)] = []
            pairs.reserveCapacity(ordered.count)
            for (w, _) in ordered {
                let k = WordEngine.key(w)
                if best[k] == nil { best[k] = w }
                pairs.append((k, w))
                let letters = k.filter { $0.isLetter }
                if let first = letters.first, let last = letters.last {
                    swipe[String([first, last]), default: []].append(w)
                }
            }
            pairs.sort { $0.0 < $1.0 }

            DispatchQueue.main.async {
                self.freq = f
                self.bestByKey = best
                self.sortedKeys = pairs.map { $0.0 }
                self.sortedWords = pairs.map { $0.1 }
                self.swipeIndex = swipe
                self.loaded = true
                self.loading = false
                self.setProtected(extra: extra, learned: learned)
                completion()
            }
        }
    }

    private func setProtected(extra: [String], learned: [String]) {
        protected = Set((extra + learned).map { $0.lowercased() })
    }

    func learn(_ word: String) {
        let w = word.lowercased()
        protected.insert(w)
        if freq[w] == nil { freq[w] = 50 }
        let k = WordEngine.key(w)
        if bestByKey[k] == nil { bestByKey[k] = w }
    }

    func frequency(_ w: String) -> Int { freq[w.lowercased()] ?? 0 }

    // MARK: Correção

    /// Retorna a correção sugerida (em minúsculas) ou nil se a palavra está boa.
    func correction(for typed: String) -> String? {
        guard loaded else { return nil }
        let lw = typed.lowercased()
        guard lw.count >= 2, lw.allSatisfy({ $0.isLetter }) else { return nil }
        if protected.contains(lw) { return nil }
        let k = WordEngine.key(lw)

        if let known = freq[lw] {
            // Palavra existe, mas sem acento e a versão acentuada é MUITO mais comum (ex.: nao -> não)
            if k == lw, let b = bestByKey[k], b != lw, (freq[b] ?? 0) > known * 20 { return b }
            return nil
        }
        // Mesma palavra sem acento/cedilha (ex.: acao -> ação, voce -> você)
        if let b = bestByKey[k] { return b }
        // Erros de digitação: uma letra trocada, faltando, sobrando ou invertida
        guard k.count >= 3 else { return nil }
        var bestWord: String?
        var bestF = 0
        for e in WordEngine.edits1(k) {
            if let w = bestByKey[e], let f = freq[w], f > bestF {
                bestF = f
                bestWord = w
            }
        }
        return bestF >= 30 ? bestWord : nil
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    private static func edits1(_ word: String) -> Set<String> {
        let c = Array(word)
        var out = Set<String>()
        for i in 0...c.count {
            let l = Array(c[0..<i]), r = Array(c[i...])
            if !r.isEmpty { out.insert(String(l + r.dropFirst())) }
            if r.count > 1 { out.insert(String(l + [r[1], r[0]] + r.dropFirst(2))) }
            for ch in alphabet {
                if !r.isEmpty { out.insert(String(l + [ch] + r.dropFirst())) }
                out.insert(String(l + [ch] + r))
            }
        }
        out.remove(word)
        return out
    }

    // MARK: Sugestões (completar palavra)

    func completions(prefix: String, limit: Int) -> [String] {
        guard loaded, !prefix.isEmpty else { return [] }
        let p = WordEngine.key(prefix)
        var lo = 0, hi = sortedKeys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedKeys[mid] < p { lo = mid + 1 } else { hi = mid }
        }
        var found: [(String, Int)] = []
        var i = lo
        var scanned = 0
        while i < sortedKeys.count, scanned < 4000, sortedKeys[i].hasPrefix(p) {
            let w = sortedWords[i]
            found.append((w, freq[w] ?? 0))
            i += 1
            scanned += 1
        }
        found.sort { $0.1 > $1.1 }
        var out: [String] = []
        for (w, _) in found where !out.contains(w) {
            out.append(w)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Digitação deslizando

    /// path: letras por onde o dedo passou (sem repetições seguidas).
    /// corners: posições em `path` onde o dedo mudou de direção (letras que provavelmente fazem parte da palavra).
    func swipeCandidates(path: [Character], corners: Set<Int>, neighbors: [Character: [Character]], limit: Int) -> [String] {
        guard loaded, let first = path.first, let last = path.last else { return [] }
        let firsts = [first] + (neighbors[first] ?? [])
        let lasts = [last] + (neighbors[last] ?? [])
        var scored: [(String, Double)] = []

        for (fi, f) in firsts.enumerated() {
            for (li, l) in lasts.enumerated() {
                guard let words = swipeIndex[String([f, l])] else { continue }
                for w in words {
                    let k = Array(WordEngine.key(w).filter { $0.isLetter })
                    guard !k.isEmpty else { continue }
                    // remove letras repetidas seguidas (carro -> caro)
                    var collapsed: [Character] = []
                    for ch in k where collapsed.last != ch { collapsed.append(ch) }
                    if collapsed.count > path.count + 1 { continue }
                    guard let matched = WordEngine.subsequenceMatch(collapsed, in: path, firstFree: fi > 0, lastFree: li > 0) else { continue }
                    let missedCorners = corners.subtracting(matched).count
                    let fq = Double(freq[w] ?? 1)
                    var score = log(fq + 1) + Double(collapsed.count) * 1.4
                    score -= Double(missedCorners) * 3.0
                    if fi > 0 { score -= 2.5 }
                    if li > 0 { score -= 2.5 }
                    if collapsed.count == 1 && path.count > 2 { score -= 4 }
                    scored.append((w, score))
                }
            }
        }
        scored.sort { $0.1 > $1.1 }
        var out: [String] = []
        for (w, _) in scored where !out.contains(w) {
            out.append(w)
            if out.count >= limit { break }
        }
        return out
    }

    /// Verifica se `word` cabe no caminho: começa no início, termina no fim
    /// e as letras do meio aparecem na ordem. Devolve os índices usados.
    private static func subsequenceMatch(_ word: [Character], in path: [Character], firstFree: Bool, lastFree: Bool) -> Set<Int>? {
        let n = word.count, m = path.count
        guard n >= 1, m >= 1 else { return nil }
        if !firstFree && word[0] != path[0] { return nil }
        if n == 1 { return [0, m - 1] }
        if !lastFree && word[n - 1] != path[m - 1] { return nil }
        var used: Set<Int> = [0, m - 1]
        var pi = 1
        if n > 2 {
            for wi in 1..<(n - 1) {
                while pi < m - 1 && path[pi] != word[wi] { pi += 1 }
                if pi >= m - 1 { return nil }
                used.insert(pi)
                pi += 1
            }
        }
        return used
    }
}
