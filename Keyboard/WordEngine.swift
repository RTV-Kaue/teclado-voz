import Foundation
import CoreGraphics

/// Dicionário de português + modelo de linguagem simples.
/// Usado para correção automática, sugestões, previsão da próxima palavra e digitação deslizando.
final class WordEngine {
    static let shared = WordEngine()

    private(set) var loaded = false
    private var loading = false

    private var freq: [String: Int] = [:]              // palavra (minúscula) -> frequência
    private var display: [String: String] = [:]        // grafia especial (Pedro, TC)
    private var bestByKey: [String: String] = [:]      // sem acento -> palavra mais usada
    private var sortedKeys: [String] = []              // chaves sem acento, em ordem alfabética
    private var sortedWords: [String] = []

    private struct SwipeEntry {
        let word: String
        let path: [Character]                          // letras sem acento, sem repetição seguida
    }
    private var swipeIndex: [String: [SwipeEntry]] = [:] // primeira+última letra -> palavras

    private var protected: Set<String> = []            // vocabulário técnico + palavras aprendidas
    private var blocked: Set<String> = []              // palavras que o usuário não quer ver
    private var boost = 1000                           // frequência dada a palavras aprendidas

    private var bigrams: [String: [(String, Int)]] = [:] // palavra -> próximas mais comuns (^ = início de frase)
    private var bigramTotals: [String: Int] = [:]
    private var userBigrams: [String: [String: Int]] = [:]
    private var userUnigrams: [String: Int] = [:]
    private var userChanges = 0

    private let queue = DispatchQueue(label: "WordEngine", qos: .userInitiated)

    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    static func swipePath(_ w: String) -> [Character] {
        var out: [Character] = []
        for ch in key(w) where ch.isLetter && ch.isASCII {
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    // MARK: Carregamento

    func load(extra: [String], learned: [String], blocked blockedList: [String], completion: @escaping () -> Void) {
        if loaded {
            applyLists(extra: extra, learned: learned, blocked: blockedList)
            completion()
            return
        }
        guard !loading else { return }
        loading = true
        queue.async {
            var f: [String: Int] = [:]
            var disp: [String: String] = [:]
            if let url = Bundle.main.url(forResource: "palavras", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                text.enumerateLines { line, _ in
                    guard let sp = line.lastIndex(of: " "), let n = Int(line[line.index(after: sp)...]) else { return }
                    let original = String(line[..<sp])
                    let w = original.lowercased()
                    guard !w.isEmpty else { return }
                    if f[w] == nil || n > f[w]! { f[w] = n }
                    if original != w { disp[w] = original }
                }
            }
            let topFreq = f.values.max() ?? 1000
            let boostValue = max(topFreq / 50, 100)
            for t in extra where !t.isEmpty {
                let w = t.lowercased()
                f[w] = max(f[w] ?? 0, boostValue)
                if t != w { disp[w] = t }
            }
            for t in learned where !t.isEmpty {
                let w = t.lowercased()
                f[w] = max(f[w] ?? 0, boostValue)
            }

            var big: [String: [(String, Int)]] = [:]
            var totals: [String: Int] = [:]
            if let url = Bundle.main.url(forResource: "bigramas", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                text.enumerateLines { line, _ in
                    let parts = line.split(separator: "\t")
                    guard parts.count == 2 else { return }
                    var list: [(String, Int)] = []
                    var total = 0
                    for item in parts[1].split(separator: " ") {
                        guard let c = item.lastIndex(of: ":"), let n = Int(item[item.index(after: c)...]) else { continue }
                        list.append((String(item[..<c]), n))
                        total += n
                    }
                    big[String(parts[0])] = list
                    totals[String(parts[0])] = total
                }
            }

            let ordered = f.sorted { $0.value > $1.value }
            var best: [String: String] = [:]
            var swipe: [String: [SwipeEntry]] = [:]
            var pairs: [(String, String)] = []
            pairs.reserveCapacity(ordered.count)
            for (w, _) in ordered {
                let k = WordEngine.key(w)
                if best[k] == nil { best[k] = w }
                pairs.append((k, w))
                let path = WordEngine.swipePath(w)
                if let first = path.first, let last = path.last {
                    swipe[String([first, last]), default: []].append(SwipeEntry(word: w, path: path))
                }
            }
            pairs.sort { $0.0 < $1.0 }

            DispatchQueue.main.async {
                self.freq = f
                self.display = disp
                self.bestByKey = best
                self.sortedKeys = pairs.map { $0.0 }
                self.sortedWords = pairs.map { $0.1 }
                self.swipeIndex = swipe
                self.bigrams = big
                self.bigramTotals = totals
                self.boost = boostValue
                self.userBigrams = (Shared.defaults?.dictionary(forKey: "user.bigrams") as? [String: [String: Int]]) ?? [:]
                self.userUnigrams = (Shared.defaults?.dictionary(forKey: "user.unigrams") as? [String: Int]) ?? [:]
                self.swipeWanted = (Shared.defaults?.dictionary(forKey: "swipe.wanted") as? [String: Int]) ?? [:]
                self.swipeRejected = (Shared.defaults?.dictionary(forKey: "swipe.rejected") as? [String: Int]) ?? [:]
                self.loaded = true
                self.loading = false
                self.applyLists(extra: extra, learned: learned, blocked: blockedList)
                completion()
            }
        }
    }

    private func applyLists(extra: [String], learned: [String], blocked blockedList: [String]) {
        protected = Set((extra + learned).map { $0.lowercased() })
        blocked = Set(blockedList.map { $0.lowercased() })
        for w in learned { addWord(w.lowercased()) }
        for t in extra where !t.isEmpty {
            addWord(t.lowercased())
            if t != t.lowercased() { display[t.lowercased()] = t }
        }
    }

    /// Palavra aprendida: fica bem frequente e vira a correção preferida
    func learn(_ word: String) {
        let w = word.lowercased()
        blocked.remove(w)
        protected.insert(w)
        addWord(w)
    }

    /// "Não sugerir mais": some das sugestões, correções, previsões e do deslizar
    func block(_ word: String) {
        let w = word.lowercased()
        blocked.insert(w)
        protected.remove(w)
    }

    func isBlocked(_ w: String) -> Bool { blocked.contains(w.lowercased()) }

    private func addWord(_ w: String) {
        guard !w.isEmpty else { return }
        let isNew = freq[w] == nil
        freq[w] = max(freq[w] ?? 0, boost)
        let k = WordEngine.key(w)
        bestByKey[k] = w
        guard isNew else { return }
        var lo = 0, hi = sortedKeys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedKeys[mid] < k { lo = mid + 1 } else { hi = mid }
        }
        sortedKeys.insert(k, at: lo)
        sortedWords.insert(w, at: lo)
        let path = WordEngine.swipePath(w)
        if let first = path.first, let last = path.last {
            swipeIndex[String([first, last]), default: []].insert(SwipeEntry(word: w, path: path), at: 0)
        }
    }

    func frequency(_ w: String) -> Int { freq[w.lowercased()] ?? 0 }

    /// Grafia para mostrar (Pedro, TC); palavras comuns ficam como estão
    func displayForm(_ w: String) -> String { display[w.lowercased()] ?? w }

    // MARK: Pontuação das palavras (frequência + contexto + seu uso)

    private func baseScore(_ w: String) -> Double {
        log(Double(freq[w] ?? 1) + 1)
    }

    /// Quanto a palavra combina com a anterior e com o seu jeito de escrever
    private func contextScore(_ w: String, prev: String?) -> Double {
        var s = 0.0
        if let p = prev {
            if let list = bigrams[p], let total = bigramTotals[p], total > 0,
               let hit = list.first(where: { $0.0 == w }) {
                s += 2.0 * log(1 + 30 * Double(hit.1) / Double(total))
            }
            if let u = userBigrams[p]?[w] { s += 1.5 * log(1 + Double(u)) }
        }
        if let u = userUnigrams[w] { s += 0.7 * log(1 + Double(u)) }
        return s
    }

    private func score(_ w: String, prev: String?) -> Double {
        baseScore(w) + contextScore(w, prev: prev)
    }

    // MARK: Correção

    /// Retorna a correção sugerida (em minúsculas) ou nil se a palavra está boa.
    func correction(for typed: String, prev: String? = nil) -> String? {
        guard loaded else { return nil }
        let lw = typed.lowercased()
        guard lw.count >= 2, lw.allSatisfy({ $0.isLetter }) else { return nil }
        if protected.contains(lw) { return nil }
        let r = rawCorrection(lw, prev: prev)
        if let r, blocked.contains(r) { return nil }
        return r
    }

    private func rawCorrection(_ lw: String, prev: String?) -> String? {
        let k = WordEngine.key(lw)
        if let known = freq[lw] {
            // Palavra existe, mas sem acento e a versão acentuada é MUITO mais comum (ex.: nao -> não)
            if k == lw, let b = bestByKey[k], b != lw, (freq[b] ?? 0) > known * 20 { return b }
            // Palavra rara muito parecida com uma comum: ahora -> agora
            if k.count >= 4, let (w, f) = bestEdit(k, prev: prev), w != lw, f > known * 50 { return w }
            return nil
        }
        // Mesma palavra sem acento/cedilha (ex.: acao -> ação, voce -> você)
        if let b = bestByKey[k] { return b }
        // Erros de digitação: uma letra trocada, faltando, sobrando ou invertida
        guard k.count >= 3, let (w, f) = bestEdit(k, prev: prev), f >= 30 else { return nil }
        return w
    }

    /// Palavra mais provável a uma letra de distância, levando em conta a frase
    private func bestEdit(_ k: String, prev: String?) -> (String, Int)? {
        var bestWord: String?
        var bestScore = -Double.infinity
        for e in WordEngine.edits1(k) {
            guard let w = bestByKey[e], !blocked.contains(w), freq[w] != nil else { continue }
            let s = score(w, prev: prev)
            if s > bestScore {
                bestScore = s
                bestWord = w
            }
        }
        guard let bestWord, let f = freq[bestWord] else { return nil }
        return (bestWord, f)
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

    func completions(prefix: String, prev: String? = nil, limit: Int) -> [String] {
        guard loaded, !prefix.isEmpty else { return [] }
        let p = WordEngine.key(prefix)
        var lo = 0, hi = sortedKeys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedKeys[mid] < p { lo = mid + 1 } else { hi = mid }
        }
        var found: [(String, Double)] = []
        var i = lo
        var scanned = 0
        while i < sortedKeys.count, scanned < 4000, sortedKeys[i].hasPrefix(p) {
            let w = sortedWords[i]
            if !blocked.contains(w) { found.append((w, score(w, prev: prev))) }
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

    // MARK: Previsão da próxima palavra

    /// prev = palavra anterior (minúscula) ou "^" no começo de frase
    func predictions(after prev: String, limit: Int) -> [String] {
        guard loaded else { return [] }
        var scores: [String: Double] = [:]
        if let list = bigrams[prev] {
            for (w, c) in list where !blocked.contains(w) {
                scores[w, default: 0] += log(1 + Double(c))
            }
        }
        if let mine = userBigrams[prev] {
            for (w, c) in mine where !blocked.contains(w) {
                scores[w, default: 0] += 2.5 * log(1 + Double(c)) + 1
            }
        }
        return scores.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    /// Aprende a palavra e a sequência que a pessoa escreveu
    func recordPair(prev: String, word: String) {
        let p = prev.lowercased(), w = word.lowercased()
        guard !w.isEmpty, w.allSatisfy({ $0.isLetter || $0 == "-" }), !blocked.contains(w) else { return }
        userBigrams[p, default: [:]][w, default: 0] += 1
        userUnigrams[w, default: 0] += 1
        userChanges += 1
        if userChanges >= 10 { saveUserBigrams() }
    }

    func saveUserBigrams() {
        guard userChanges > 0 else { return }
        userChanges = 0
        if userBigrams.count > 4000 {
            let keep = userBigrams.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }.prefix(3000)
            userBigrams = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if userUnigrams.count > 6000 {
            let keep = userUnigrams.sorted { $0.value > $1.value }.prefix(5000)
            userUnigrams = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        Shared.defaults?.set(userBigrams, forKey: "user.bigrams")
        Shared.defaults?.set(userUnigrams, forKey: "user.unigrams")
    }

    func forgetUserBigrams() {
        userBigrams = [:]
        userUnigrams = [:]
        swipeWanted = [:]
        swipeRejected = [:]
        userChanges = 0
    }

    // MARK: Digitação deslizando (comparando o desenho do caminho)

    private static let samples = 24
    private static let sigmaLocation = 0.45   // tolerância de posição, em larguras de tecla
    private static let sigmaShape = 0.06      // tolerância do formato do desenho
    private static let sigmaEnds = 0.5        // tolerância do começo e do fim

    // Aprendizado do deslizar: palavras que você aceitou/corrigiu e as que rejeitou
    private var swipeWanted: [String: Int] = [:]
    private var swipeRejected: [String: Int] = [:]

    func swipeFeedback(rejected: String?, wanted: String?) {
        if let r = rejected?.lowercased(), !r.isEmpty { swipeRejected[r, default: 0] += 1 }
        if let w = wanted?.lowercased(), !w.isEmpty { swipeWanted[w, default: 0] += 1 }
        Shared.defaults?.set(swipeWanted, forKey: "swipe.wanted")
        Shared.defaults?.set(swipeRejected, forKey: "swipe.rejected")
    }

    /// Formato do desenho, sem depender de posição e tamanho
    private static func shape(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard !pts.isEmpty else { return pts }
        var c = SIMD2<Double>(0, 0)
        var minP = pts[0], maxP = pts[0]
        for p in pts {
            c += p
            minP = SIMD2(min(minP.x, p.x), min(minP.y, p.y))
            maxP = SIMD2(max(maxP.x, p.x), max(maxP.y, p.y))
        }
        c /= Double(pts.count)
        let size = max(maxP.x - minP.x, maxP.y - minP.y, 1e-6)
        return pts.map { ($0 - c) / size }
    }

    /// points: caminho do dedo; centers: centro de cada tecla de letra; keyWidth: largura de uma tecla
    func swipeDecode(points: [CGPoint], centers: [Character: CGPoint], keyWidth: CGFloat,
                     prev: String?, limit: Int) -> [String] {
        guard loaded, points.count >= 2, keyWidth > 0, let start = points.first, let end = points.last else { return [] }
        let kw = Double(keyWidth)
        func norm(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x) / kw, Double(p.y) / kw) }

        let user = points.map(norm)
        let userLen = WordEngine.length(user)
        let userR = WordEngine.resample(user, WordEngine.samples)
        let userShape = WordEngine.shape(userR)
        var c: [Character: SIMD2<Double>] = [:]
        for (ch, p) in centers { c[ch] = norm(p) }

        let s = norm(start), e = norm(end)
        let firsts = c.filter { WordEngine.simdDist($0.value, s) < 1.5 }.map { $0.key }
        let lasts = c.filter { WordEngine.simdDist($0.value, e) < 1.5 }.map { $0.key }

        var scored: [(String, Double)] = []
        for f in firsts {
            for l in lasts {
                guard let entries = swipeIndex[String([f, l])] else { continue }
                for entry in entries where !blocked.contains(entry.word) {
                    var ideal: [SIMD2<Double>] = []
                    ideal.reserveCapacity(entry.path.count)
                    var ok = true
                    for ch in entry.path {
                        guard let p = c[ch] else { ok = false; break }
                        ideal.append(p)
                    }
                    guard ok, !ideal.isEmpty else { continue }
                    // o dedo andou: não é palavra de uma letra só
                    if ideal.count == 1 && userLen > 0.7 { continue }
                    let idealLen = WordEngine.length(ideal)
                    if idealLen > 1.6 * userLen + 1.5 || idealLen < 0.5 * userLen - 1.5 { continue }
                    let idealR = WordEngine.resample(ideal, WordEngine.samples)
                    var d = 0.0
                    for i in 0..<WordEngine.samples { d += WordEngine.simdDist(userR[i], idealR[i]) }
                    d /= Double(WordEngine.samples)
                    var dShape = 0.0
                    if ideal.count > 1 {
                        let idealShape = WordEngine.shape(idealR)
                        for i in 0..<WordEngine.samples { dShape += WordEngine.simdDist(userShape[i], idealShape[i]) }
                        dShape /= Double(WordEngine.samples)
                    }
                    let sl = WordEngine.sigmaLocation, ss = WordEngine.sigmaShape
                    let geo = -(d * d) / (2 * sl * sl) - (dShape * dShape) / (2 * ss * ss)
                    // começo e fim do traçado pesam mais (importante em palavras curtas como "oi")
                    let ds = WordEngine.simdDist(s, ideal[0]), de = WordEngine.simdDist(e, ideal[ideal.count - 1])
                    let se = WordEngine.sigmaEnds
                    let ends = -(ds * ds + de * de) / (2 * se * se)
                    var total = geo + ends + 0.45 * baseScore(entry.word) + 0.6 * contextScore(entry.word, prev: prev)
                    if let wnt = swipeWanted[entry.word] { total += 1.2 * log(1 + Double(wnt)) }
                    if let rej = swipeRejected[entry.word] { total -= 1.0 * log(1 + Double(rej)) }
                    scored.append((entry.word, total))
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

    private static func simdDist(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    private static func length(_ pts: [SIMD2<Double>]) -> Double {
        guard pts.count > 1 else { return 0 }
        var l = 0.0
        for i in 1..<pts.count { l += simdDist(pts[i - 1], pts[i]) }
        return l
    }

    /// Redistribui o caminho em n pontos igualmente espaçados
    private static func resample(_ pts: [SIMD2<Double>], _ n: Int) -> [SIMD2<Double>] {
        guard let first = pts.first else { return [] }
        let total = length(pts)
        if pts.count == 1 || total == 0 { return Array(repeating: first, count: n) }
        let step = total / Double(n - 1)
        var out: [SIMD2<Double>] = [first]
        var acc = 0.0
        var prev = first
        var i = 1
        while i < pts.count && out.count < n {
            let d = simdDist(prev, pts[i])
            if acc + d >= step && d > 0 {
                let t = (step - acc) / d
                let q = prev + (pts[i] - prev) * t
                out.append(q)
                prev = q
                acc = 0
            } else {
                acc += d
                prev = pts[i]
                i += 1
            }
        }
        while out.count < n { out.append(pts[pts.count - 1]) }
        return out
    }
}
