import UIKit
import AudioToolbox

final class KeyboardViewController: UIInputViewController, KeysContainerDelegate {

    enum ShiftState { case off, on, locked }

    private struct ActiveTouch {
        let key: KeyView
        let start: CGPoint
        var lastX: CGFloat
        var committed = false
        var cursorMoved = false
        var longTimer: Timer?
        var popupIndex: Int?
        // deslizar
        var swiping = false
        var points: [CGPoint] = []
        var seq: [Character] = []
        var seqIdx: [Int] = []
    }

    private struct Suggestion {
        let title: String
        let insert: String
        let deleteCount: Int
        let learn: String?
        let highlight: Bool
    }

    static let accents: [String: [String]] = [
        "a": ["á", "ã", "â", "à", "ä", "ª"],
        "e": ["é", "ê", "è", "ë"],
        "i": ["í", "î", "ì", "ï"],
        "o": ["ó", "õ", "ô", "ò", "ö", "º"],
        "u": ["ú", "ü", "ù", "û"],
        "c": ["ç"],
        "n": ["ñ"],
        ".": ["…", "!", "?"],
        ",": [";", ":"],
        "-": ["–", "—"],
        "'": ["\""]
    ]

    private var settings = KeyboardSettings.load()
    private let engine = WordEngine.shared
    private var currentLayer: KeyboardLayer = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var heightConstraint: NSLayoutConstraint?
    private let topBarHeight: CGFloat = 38

    private let topBar = UIView()
    private let statusLabel = UILabel()
    private let suggestionStack = UIStackView()
    private var suggestionButtons: [UIButton] = []
    private var suggestions: [Suggestion] = []
    private let micButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let container = KeysContainer()
    private let rowsStack = UIStackView()
    private let trail = CAShapeLayer()

    private var letterKeys: [KeyView] = []
    private var shiftKey: KeyView?
    private var returnKey: KeyView?

    private var active: [UITouch: ActiveTouch] = [:]
    private var popup: UIView?
    private var popupLabels: [UILabel] = []
    private var popupOptions: [String] = []
    private var popupFrame: CGRect = .zero

    private var deleteTimer: Timer?
    private var deleteCount = 0
    private var pollTimer: Timer?
    private var waitingResult = false
    private var waitingSince = Date.distantPast
    private var lastStatusKey = ""
    private let observer = DarwinObserver()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // correção e deslizar
    private var lastCorrection: (original: String, corrected: String, sep: String)?
    private var lastSwipe: (word: String, alternates: [String])?
    private var pendingSwipeSpace = false
    private var isVisible = false

    // MARK: Ciclo de vida

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTopBar()

        container.delegate = self
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        rowsStack.axis = .vertical
        rowsStack.distribution = .fillEqually
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rowsStack)

        trail.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55).cgColor
        trail.fillColor = nil
        trail.lineWidth = 7
        trail.lineCap = .round
        trail.lineJoin = .round
        container.layer.addSublayer(trail)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: topBarHeight),
            container.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rowsStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            rowsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            rowsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            rowsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])

        observer.observe(DarwinNote.state) { [weak self] in self?.refreshStatus() }
        observer.observe(DarwinNote.result) { [weak self] in self?.insertResultIfNew() }
        observer.observe(DarwinNote.settings) { [weak self] in self?.settingsChanged() }

        loadDictionary()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        settings = KeyboardSettings.load()
        rebuildKeys()
        updateHeight()
        autoCap()
        haptic.prepare()
        insertResultIfNew()
        lastStatusKey = ""
        refreshStatus()
        updateSuggestions()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // O sistema atrasa toques perto das bordas da tela; isso deixa o teclado "engasgado"
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        var v: UIView? = view.superview
        while let s = v {
            s.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
            v = s.superview
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        pollTimer?.invalidate()
        pollTimer = nil
        stopDeleteRepeat()
        hidePopup()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        autoCap()
        updateReturnKey()
        updateSuggestions()
    }

    private func settingsChanged() {
        settings = KeyboardSettings.load()
        rebuildKeys()
        updateHeight()
        loadDictionary()
        updateSuggestions()
    }

    private func loadDictionary() {
        let learned = Shared.defaults?.stringArray(forKey: K.learned) ?? []
        engine.load(extra: settings.vocabulary, learned: learned) { [weak self] in
            self?.updateSuggestions()
        }
    }

    // MARK: Barra superior (microfone e sugestões)

    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismissButton.tintColor = .secondaryLabel
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingHead
        statusLabel.numberOfLines = 1

        suggestionStack.axis = .horizontal
        suggestionStack.distribution = .fillEqually
        suggestionStack.spacing = 4
        suggestionStack.isHidden = true
        for i in 0..<3 {
            let b = UIButton(type: .system)
            b.tag = i
            b.titleLabel?.font = .systemFont(ofSize: 17)
            b.titleLabel?.lineBreakMode = .byTruncatingTail
            b.setTitleColor(.label, for: .normal)
            b.layer.cornerRadius = 8
            b.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            suggestionButtons.append(b)
            suggestionStack.addArrangedSubview(b)
        }

        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.image = UIImage(systemName: "mic.fill")
        micButton.configuration = cfg
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        for v in [dismissButton, statusLabel, suggestionStack, micButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            dismissButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 34),
            dismissButton.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            suggestionStack.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 2),
            suggestionStack.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -6),
            suggestionStack.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 3),
            suggestionStack.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -3),
            micButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            micButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 58),
            micButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    @objc private func dismissTapped() { dismissKeyboard() }

    @objc private func micTapped() {
        if settings.haptics && hasFullAccess { haptic.impactOccurred() }
        guard hasFullAccess, let d = Shared.defaults else { refreshStatus(); return }
        setSuggestions([])
        if Shared.sessionAlive {
            if d.bool(forKey: K.recording) {
                DarwinNote.post(DarwinNote.stop)
                waitingResult = true
                waitingSince = Date()
            } else {
                DarwinNote.post(DarwinNote.start)
            }
        } else if let url = URL(string: "\(Shared.urlScheme)://dictate") {
            statusLabel.text = openContainingApp(url)
                ? "Abrindo o app… depois toque em ◀ para voltar"
                : "Abra o app Teclado Voz para ativar o ditado"
            return
        }
        lastStatusKey = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshStatus() }
    }

    private var isDictating: Bool {
        let alive = Shared.sessionAlive
        return waitingResult || (alive && (Shared.defaults?.bool(forKey: K.recording) ?? false))
    }

    private func refreshStatus() {
        let d = Shared.defaults
        let alive = Shared.sessionAlive
        let recording = alive && (d?.bool(forKey: K.recording) ?? false)
        if waitingResult && Date().timeIntervalSince(waitingSince) > 6 { waitingResult = false }

        let state: String
        var text: String
        let image: String
        let color: UIColor
        if !hasFullAccess {
            state = "noaccess"; text = "Ative “Permitir Acesso Total” nos Ajustes"
            image = "mic.slash"; color = .systemGray
        } else if d == nil {
            state = "nogroup"; text = "Erro: grupo de app não encontrado"
            image = "exclamationmark.triangle"; color = .systemGray
        } else if recording {
            state = "rec"
            let p = d?.string(forKey: K.partial) ?? ""
            text = p.isEmpty ? "Ouvindo… fale agora" : p
            image = "stop.fill"; color = .systemRed
        } else if waitingResult {
            state = "wait"; text = "Processando…"
            image = "ellipsis"; color = .systemOrange
        } else if alive {
            state = "ready"; text = ""
            image = "mic.fill"; color = .systemBlue
        } else {
            state = "off"; text = ""
            image = "mic"; color = .systemGray
        }
        if statusLabel.text != text { statusLabel.text = text }
        if (state == "rec" || state == "wait") && !suggestions.isEmpty { setSuggestions([]) }
        guard state != lastStatusKey else { return }
        lastStatusKey = state
        var cfg = micButton.configuration ?? .filled()
        cfg.image = UIImage(systemName: image)
        cfg.baseBackgroundColor = color
        micButton.configuration = cfg
    }

    private func insertResultIfNew() {
        // Um teclado antigo (de outro app) ainda pode estar na memória: só o visível insere
        guard isVisible, let d = Shared.defaults else { return }
        let id = d.integer(forKey: K.resultID)
        guard id > d.integer(forKey: K.consumedID) else { return }
        d.set(id, forKey: K.consumedID)
        waitingResult = false
        lastStatusKey = ""
        let age = Date().timeIntervalSince1970 - d.double(forKey: K.resultTime)
        guard age < 30, let raw = d.string(forKey: K.result), !raw.isEmpty else { refreshStatus(); return }
        textDocumentProxy.insertText(adjustForContext(raw))
        clearWordState()
        autoCap()
        refreshStatus()
    }

    /// Ajusta espaço e maiúscula de acordo com o que já está escrito antes do cursor
    private func adjustForContext(_ raw: String) -> String {
        var text = raw
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, !".!?\n".contains(last) {
            let chars = Array(text)
            if chars.count > 1, chars[0].isUppercase, chars[1].isLowercase {
                text = chars[0].lowercased() + String(chars.dropFirst())
            }
        }
        if let last = before.last, !last.isWhitespace,
           let first = text.first, !",.;:!?".contains(first) {
            text = " " + text
        }
        return text
    }

    /// Extensões de teclado não podem abrir URLs diretamente; usamos a cadeia de responders.
    private func openContainingApp(_ url: URL) -> Bool {
        typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary,
                                           (@convention(block) (Bool) -> Void)?) -> Void
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: sel) {
                let fn = unsafeBitCast(app.method(for: sel), to: OpenFn.self)
                fn(app, sel, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        // Plano B: pegar o UIApplication compartilhado por nome
        let shared = NSSelectorFromString("sharedApplication")
        if let cls = NSClassFromString("UIApplication") as? NSObject.Type,
           cls.responds(to: shared),
           let app = cls.perform(shared)?.takeUnretainedValue() as? UIApplication,
           app.responds(to: sel) {
            let fn = unsafeBitCast(app.method(for: sel), to: OpenFn.self)
            fn(app, sel, url as NSURL, NSDictionary(), nil)
            return true
        }
        return false
    }

    // MARK: Sugestões

    private func setSuggestions(_ items: [Suggestion]) {
        suggestions = Array(items.prefix(3))
        let show = !suggestions.isEmpty
        suggestionStack.isHidden = !show
        statusLabel.isHidden = show
        for (i, b) in suggestionButtons.enumerated() {
            if i < suggestions.count {
                let s = suggestions[i]
                b.isHidden = false
                b.setTitle(s.title, for: .normal)
                b.titleLabel?.font = s.highlight ? .boldSystemFont(ofSize: 17) : .systemFont(ofSize: 17)
                b.backgroundColor = s.highlight ? KeyView.normalColor.withAlphaComponent(0.6) : .clear
            } else {
                b.isHidden = true
            }
        }
    }

    private func updateSuggestions() {
        guard engine.loaded, !isDictating, currentLayer == .letters || pendingSwipeSpace else {
            setSuggestions([])
            return
        }
        if pendingSwipeSpace, let s = lastSwipe {
            let items = s.alternates.map {
                Suggestion(title: $0, insert: $0 + " ", deleteCount: s.word.count + 1, learn: nil, highlight: false)
            }
            setSuggestions(items)
            return
        }
        let w = currentWord()
        guard !w.isEmpty, w.allSatisfy({ $0.isLetter }) else {
            setSuggestions([])
            return
        }
        var items: [Suggestion] = []
        if settings.autocorrect, !isProtected(w), let c = engine.correction(for: w) {
            let fixed = matchCase(c, like: w)
            if fixed != w {
                items.append(Suggestion(title: "“\(w)”", insert: w + " ", deleteCount: w.count, learn: w, highlight: false))
                items.append(Suggestion(title: fixed, insert: fixed + " ", deleteCount: w.count, learn: nil, highlight: true))
            }
        }
        for c in engine.completions(prefix: w, limit: 5) {
            let cc = matchCase(c, like: w)
            if cc != w && !items.contains(where: { $0.title == cc }) && items.count < 3 {
                items.append(Suggestion(title: cc, insert: cc + " ", deleteCount: w.count, learn: nil, highlight: false))
            }
        }
        setSuggestions(items)
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard sender.tag < suggestions.count else { return }
        let s = suggestions[sender.tag]
        if settings.haptics && hasFullAccess { haptic.impactOccurred() }
        for _ in 0..<s.deleteCount { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(s.insert)
        if let l = s.learn { learnWord(l) }
        let wasSwipe = pendingSwipeSpace
        clearWordState()
        pendingSwipeSpace = wasSwipe
        autoCap()
        updateSuggestions()
    }

    private func learnWord(_ w: String) {
        engine.learn(w)
        guard let d = Shared.defaults else { return }
        var arr = d.stringArray(forKey: K.learned) ?? []
        if !arr.contains(w.lowercased()) {
            arr.append(w.lowercased())
            d.set(Array(arr.suffix(2000)), forKey: K.learned)
        }
    }

    private func clearWordState() {
        lastCorrection = nil
        lastSwipe = nil
        pendingSwipeSpace = false
    }

    /// Palavra que está sendo digitada (antes do cursor)
    private func currentWord() -> String {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        var chars: [Character] = []
        for ch in before.reversed() {
            if ch.isLetter || ch.isNumber || ch == "-" { chars.append(ch) } else { break }
        }
        return String(chars.reversed())
    }

    private func isProtected(_ w: String) -> Bool {
        if w.count >= 2 && w == w.uppercased() { return true } // siglas: TC, SEL, IEC
        let lw = w.lowercased()
        return settings.vocabulary.contains { $0.lowercased() == lw }
    }

    private func matchCase(_ word: String, like typed: String) -> String {
        if typed.count >= 2 && typed == typed.uppercased() { return word.uppercased() }
        if let f = typed.first, f.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }

    /// Corrige a palavra atual antes de um espaço/pontuação. Retorna true se corrigiu.
    private func autocorrectCurrentWord() -> (String, String)? {
        guard settings.autocorrect, engine.loaded else { return nil }
        let w = currentWord()
        guard w.count >= 2, w.allSatisfy({ $0.isLetter }), !isProtected(w),
              let c = engine.correction(for: w) else { return nil }
        let fixed = matchCase(c, like: w)
        guard fixed != w else { return nil }
        for _ in 0..<w.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(fixed)
        return (w, fixed)
    }

    /// Apagar logo depois de uma correção volta a palavra original (e aprende ela)
    private func undoAutocorrect() -> Bool {
        guard let lc = lastCorrection else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(lc.corrected + lc.sep) else { lastCorrection = nil; return false }
        for _ in 0..<(lc.corrected.count + lc.sep.count) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(lc.original)
        learnWord(lc.original)
        lastCorrection = nil
        return true
    }

    /// Apagar logo depois de deslizar apaga a palavra inteira
    private func undoSwipe() -> Bool {
        guard pendingSwipeSpace, let s = lastSwipe else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(s.word + " ") else { clearWordState(); return false }
        for _ in 0..<(s.word.count + 1) { textDocumentProxy.deleteBackward() }
        clearWordState()
        return true
    }

    // MARK: Montagem das teclas

    private func updateHeight() {
        let keyH = CGFloat(settings.keyHeight)
        let gap = CGFloat(settings.keySpacing) * 1.6
        let h = topBarHeight + 4 * keyH + 3 * gap + 12
        if let c = heightConstraint {
            c.constant = h
        } else {
            let c = view.heightAnchor.constraint(equalToConstant: h)
            c.priority = UILayoutPriority(999)
            c.isActive = true
            heightConstraint = c
        }
    }

    private func makeKey(_ kind: KeyKind, title: String? = nil, symbol: String? = nil,
                         special: Bool, alternates: [String] = []) -> KeyView {
        let k = KeyView(kind: kind, title: title, symbol: symbol, special: special,
                        alternates: alternates, fontSize: CGFloat(settings.fontSize))
        container.keys.append(k)
        return k
    }

    private func charKey(_ c: String) -> KeyView {
        makeKey(.char(c), title: c, special: false, alternates: Self.accents[c] ?? [])
    }

    private func makeRow(_ views: [UIView], equal: Bool) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal
        s.spacing = CGFloat(settings.keySpacing)
        s.distribution = equal ? .fillEqually : .fill
        return s
    }

    private func makeGlobeKey() -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "globe"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = KeyView.specialColor
        b.layer.cornerRadius = 8
        b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        return b
    }

    private func rebuildKeys() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        container.keys = []
        container.passthrough = []
        letterKeys = []
        shiftKey = nil
        returnKey = nil
        rowsStack.spacing = CGFloat(settings.keySpacing) * 1.6

        var rows: [UIStackView] = []
        // Restrições entre linhas só podem ser ativadas depois que todas estão no mesmo pai
        var pending: [NSLayoutConstraint] = []
        let unit: KeyView

        switch currentLayer {
        case .letters:
            let r1 = "qwertyuiop".map { charKey(String($0)) }
            let r2 = "asdfghjkl".map { charKey(String($0)) }
            let r3 = "zxcvbnm".map { charKey(String($0)) }
            let shiftK = makeKey(.shift, symbol: "shift", special: true)
            let del = makeKey(.delete, symbol: "delete.left", special: true)
            shiftKey = shiftK
            letterKeys = r1 + r2 + r3
            unit = r1[0]
            // linha do meio com meia tecla de recuo dos dois lados (como no iPhone)
            let padL = UIView(), padR = UIView()
            rows = [makeRow(r1, equal: true),
                    makeRow([padL] + r2 + [padR], equal: false),
                    makeRow([shiftK] + r3 + [del], equal: false)]
            for k in r2 + r3 { pending.append(k.widthAnchor.constraint(equalTo: unit.widthAnchor)) }
            pending.append(padL.widthAnchor.constraint(equalTo: padR.widthAnchor))
            pending.append(shiftK.widthAnchor.constraint(equalTo: del.widthAnchor))

        case .numbers, .symbols:
            let isNum = currentLayer == .numbers
            let r1Chars = isNum ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
                                : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
            let r2Chars = isNum ? ["-", "/", ":", ";", "(", ")", "R$", "&", "@", "\""]
                                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
            let r1 = r1Chars.map { charKey($0) }
            let r2 = r2Chars.map { charKey($0) }
            let toggle = makeKey(.layer(isNum ? .symbols : .numbers), title: isNum ? "#+=" : "123", special: true)
            let punct = [".", ",", "?", "!", "'"].map { charKey($0) }
            let del = makeKey(.delete, symbol: "delete.left", special: true)
            unit = r1[0]
            rows = [makeRow(r1, equal: true), makeRow(r2, equal: true),
                    makeRow([toggle] + punct + [del], equal: false)]
            pending.append(toggle.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.45))
            pending.append(del.widthAnchor.constraint(equalTo: toggle.widthAnchor))
            for k in punct.dropFirst() { pending.append(k.widthAnchor.constraint(equalTo: punct[0].widthAnchor)) }
        }

        // Linha de baixo: vírgula e ponto sempre visíveis
        let switchKey = makeKey(.layer(currentLayer == .letters ? .numbers : .letters),
                                title: currentLayer == .letters ? "123" : "ABC", special: true)
        let comma = charKey(",")
        let space = makeKey(.space, title: "espaço", special: false)
        let period = charKey(".")
        let ret = makeKey(.ret, symbol: "return.left", special: true)
        returnKey = ret

        var bottom: [UIView] = [switchKey]
        if needsInputModeSwitchKey {
            let globe = makeGlobeKey()
            container.passthrough.append(globe)
            bottom.append(globe)
            pending.append(globe.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.1))
        }
        bottom += [comma, space, period, ret]
        rows.append(makeRow(bottom, equal: false))

        pending.append(switchKey.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.3))
        pending.append(comma.widthAnchor.constraint(equalTo: unit.widthAnchor))
        pending.append(period.widthAnchor.constraint(equalTo: unit.widthAnchor))
        pending.append(ret.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.9))

        rows.forEach { rowsStack.addArrangedSubview($0) }
        NSLayoutConstraint.activate(pending)
        updateShiftUI()
        updateReturnKey()
    }

    private func updateReturnKey() {
        guard let ret = returnKey else { return }
        let title: String?
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: title = "ir"
        case .google, .yahoo, .search: title = "buscar"
        case .send: title = "enviar"
        case .done: title = "ok"
        case .next: title = "seguinte"
        case .join: title = "entrar"
        case .route: title = "rota"
        case .`continue`: title = "continuar"
        case .emergencyCall: title = "SOS"
        default: title = nil
        }
        if let title { ret.setTitle(title) } else { ret.setSymbol("return.left") }
    }

    // MARK: Toques

    func keyTouchBegan(_ touch: UITouch, key: KeyView, at p: CGPoint) {
        feedback(key.kind)
        key.highlighted = true

        // Digitação rápida: confirma as teclas anteriores ainda pressionadas, mantendo a ordem
        for (t, pendingTouch) in active where !pendingTouch.committed && pendingTouch.popupIndex == nil && !pendingTouch.swiping {
            var a = pendingTouch
            if case .char = a.key.kind {
                a.longTimer?.invalidate()
                a.longTimer = nil
                commit(a)
                a.committed = true
                a.key.highlighted = false
                active[t] = a
            }
        }

        var a = ActiveTouch(key: key, start: p, lastX: p.x)
        switch key.kind {
        case .delete:
            deleteTapped()
            a.committed = true
            startDeleteRepeat()
        case .shift:
            shiftTapped()
            a.committed = true
        case .char:
            if !key.alternates.isEmpty {
                a.longTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                    self?.showAlternates(for: touch)
                }
            }
        default:
            break
        }
        active[touch] = a
    }

    func keyTouchMoved(_ touch: UITouch, at p: CGPoint) {
        guard var a = active[touch] else { return }
        if a.popupIndex != nil {
            let i = popupIndex(at: touch.location(in: view))
            a.popupIndex = i
            highlightPopup(i)
            active[touch] = a
            return
        }

        // Começo do deslizar: saiu da tecla de letra arrastando
        if !a.swiping, !a.committed, settings.swipeTyping, currentLayer == .letters,
           case .char(let s) = a.key.kind, let ch = s.first, ch.isLetter,
           hypot(p.x - a.start.x, p.y - a.start.y) > max(a.key.bounds.width * 0.75, 18) {
            a.swiping = true
            a.longTimer?.invalidate()
            a.longTimer = nil
            a.key.highlighted = false
            a.points = [a.start]
            a.seq = [ch]
            a.seqIdx = [0]
        }
        if a.swiping {
            a.points.append(p)
            if let k = container.key(at: p), case .char(let s) = k.kind,
               let ch = s.first, ch.isLetter, a.seq.last != ch {
                a.seq.append(ch)
            }
            a.seqIdx.append(a.seq.count - 1)
            drawTrail(a.points)
            active[touch] = a
            return
        }

        // Arrastar na barra de espaço move o cursor
        if case .space = a.key.kind {
            if !a.cursorMoved && abs(p.x - a.start.x) > 14 {
                a.cursorMoved = true
                a.lastX = p.x
            }
            if a.cursorMoved {
                let step: CGFloat = 9
                let n = Int((p.x - a.lastX) / step)
                if n != 0 {
                    textDocumentProxy.adjustTextPosition(byCharacterOffset: n)
                    a.lastX += CGFloat(n) * step
                }
            }
            active[touch] = a
        }
    }

    func keyTouchEnded(_ touch: UITouch, cancelled: Bool) {
        guard let a = active.removeValue(forKey: touch) else { return }
        a.longTimer?.invalidate()
        a.key.highlighted = false
        if case .delete = a.key.kind { stopDeleteRepeat() }
        if a.swiping {
            clearTrail()
            if !cancelled { finishSwipe(a) }
            return
        }
        if let idx = a.popupIndex {
            if !cancelled, idx < popupOptions.count { insertCharacter(popupOptions[idx], raw: true) }
            hidePopup()
            return
        }
        if !a.committed {
            if !cancelled {
                commit(a)
            } else if case .char = a.key.kind {
                commit(a)   // o sistema às vezes cancela o toque; não perder a letra
            }
        }
    }

    private func commit(_ a: ActiveTouch) {
        switch a.key.kind {
        case .char(let s):
            insertCharacter(s, raw: false)
        case .space:
            if !a.cursorMoved { spaceTapped() } else { updateSuggestions() }
        case .ret:
            if let fix = autocorrectCurrentWord() {
                textDocumentProxy.insertText("\n")
                lastCorrection = (fix.0, fix.1, "\n")
            } else {
                textDocumentProxy.insertText("\n")
                lastCorrection = nil
            }
            lastSwipe = nil
            pendingSwipeSpace = false
            autoCap()
            updateSuggestions()
        case .layer(let l):
            currentLayer = l
            rebuildKeys()
            autoCap()
            updateSuggestions()
        case .shift, .delete:
            break
        }
    }

    private func insertCharacter(_ s: String, raw: Bool) {
        let isPunct = [".", ",", "!", "?", ";", ":", "…"].contains(s)
        var fix: (String, String)?
        if isPunct {
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            if pendingSwipeSpace && before.hasSuffix(" ") {
                textDocumentProxy.deleteBackward()   // "palavra ." -> "palavra."
            } else {
                fix = autocorrectCurrentWord()
            }
        }
        let text = (!raw && shift != .off && currentLayer == .letters) ? s.uppercased() : s
        textDocumentProxy.insertText(text)
        lastSwipe = nil
        pendingSwipeSpace = false
        if let fix { lastCorrection = (fix.0, fix.1, text) } else { lastCorrection = nil }
        if shift == .on {
            shift = .off
            updateShiftUI()
        }
        if currentLayer != .letters && s == "'" {
            currentLayer = .letters
            rebuildKeys()
        }
        updateSuggestions()
    }

    private func spaceTapped() {
        // Depois de deslizar o espaço já foi colocado
        if pendingSwipeSpace {
            clearWordState()
            updateSuggestions()
            return
        }
        let fix = autocorrectCurrentWord()
        let now = Date()
        let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        if fix == nil, now.timeIntervalSince(lastSpaceTap) < 0.4, ctx.hasSuffix(" "),
           let c = ctx.dropLast().last, c.isLetter || c.isNumber {
            // Espaço duplo vira ". "
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceTap = .distantPast
            lastCorrection = nil
        } else {
            textDocumentProxy.insertText(" ")
            lastSpaceTap = now
            if let fix { lastCorrection = (fix.0, fix.1, " ") } else { lastCorrection = nil }
        }
        if currentLayer != .letters {
            currentLayer = .letters
            rebuildKeys()
        }
        autoCap()
        updateSuggestions()
    }

    private func deleteTapped() {
        if undoSwipe() || undoAutocorrect() {
            autoCap()
            updateSuggestions()
            return
        }
        textDocumentProxy.deleteBackward()
        clearWordState()
        autoCap()
        updateSuggestions()
    }

    // MARK: Deslizar

    private func finishSwipe(_ a: ActiveTouch) {
        guard a.seq.count >= 2 || a.points.count > 4 else {
            commit(a)
            return
        }
        let corners = detectCorners(a.points, seqIdx: a.seqIdx)
        let cands = engine.swipeCandidates(path: a.seq, corners: corners, neighbors: neighborMap(), limit: 4)
        guard let best = cands.first else {
            if settings.haptics && hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            return
        }
        var word = best
        var alts = Array(cands.dropFirst())
        if shift == .locked {
            word = word.uppercased(); alts = alts.map { $0.uppercased() }
        } else if shift == .on {
            word = word.prefix(1).uppercased() + word.dropFirst()
            alts = alts.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if let last = before.last, !last.isWhitespace, !"([{\"'“/".contains(last) {
            textDocumentProxy.insertText(" ")
        }
        textDocumentProxy.insertText(word + " ")
        lastCorrection = nil
        lastSwipe = (word, alts)
        pendingSwipeSpace = true
        if shift == .on {
            shift = .off
            updateShiftUI()
        }
        updateSuggestions()
    }

    private func detectCorners(_ pts: [CGPoint], seqIdx: [Int]) -> Set<Int> {
        var out = Set<Int>()
        let k = 4
        guard pts.count > 2 * k, seqIdx.count == pts.count else { return out }
        for i in k..<(pts.count - k) {
            let a = pts[i - k], b = pts[i], c = pts[i + k]
            let v1x = b.x - a.x, v1y = b.y - a.y
            let v2x = c.x - b.x, v2y = c.y - b.y
            let l1 = hypot(v1x, v1y), l2 = hypot(v2x, v2y)
            guard l1 > 8, l2 > 8 else { continue }
            let cosine = (v1x * v2x + v1y * v2y) / (l1 * l2)
            if cosine < 0.3 { out.insert(seqIdx[i]) }
        }
        return out
    }

    private func neighborMap() -> [Character: [Character]] {
        var centers: [(Character, CGPoint)] = []
        for k in letterKeys {
            if case .char(let s) = k.kind, let ch = s.first {
                let f = k.convert(k.bounds, to: container)
                centers.append((ch, CGPoint(x: f.midX, y: f.midY)))
            }
        }
        let gap = CGFloat(settings.keySpacing)
        let w = (letterKeys.first?.bounds.width ?? 30) + gap
        let h = (letterKeys.first?.bounds.height ?? 50) + gap * 1.6
        var map: [Character: [Character]] = [:]
        for (c, p) in centers {
            map[c] = centers.filter { other in
                guard other.0 != c else { return false }
                let dx = (other.1.x - p.x) / w, dy = (other.1.y - p.y) / h
                return dx * dx + dy * dy < 1.5 * 1.5
            }.map { $0.0 }
        }
        return map
    }

    private func drawTrail(_ pts: [CGPoint]) {
        guard let first = pts.first else { return }
        let path = UIBezierPath()
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trail.opacity = 1
        trail.path = path.cgPath
        CATransaction.commit()
    }

    private func clearTrail() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        trail.opacity = 0
        CATransaction.commit()
    }

    // MARK: Shift / maiúsculas

    private func shiftTapped() {
        let now = Date()
        switch shift {
        case .off: shift = .on
        case .on: shift = now.timeIntervalSince(lastShiftTap) < 0.35 ? .locked : .off
        case .locked: shift = .off
        }
        lastShiftTap = now
        updateShiftUI()
    }

    private func updateShiftUI() {
        let upper = shift != .off
        for k in letterKeys {
            if case .char(let c) = k.kind { k.setTitle(upper ? c.uppercased() : c) }
        }
        shiftKey?.setSymbol(shift == .locked ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift"))
        shiftKey?.active = shift != .off
    }

    private func autoCap() {
        guard currentLayer == .letters, shift != .locked else { return }
        let type = textDocumentProxy.autocapitalizationType ?? .sentences
        let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        var cap = false
        switch type {
        case .allCharacters:
            cap = true
        case .words:
            cap = ctx.isEmpty || (ctx.last?.isWhitespace ?? true)
        case .sentences:
            let t = ctx.trimmingCharacters(in: .whitespaces)
            let endsWithSpace = ctx.last?.isWhitespace ?? true
            let sentenceEnd = t.last.map { ".!?\n".contains($0) } ?? true
            cap = t.isEmpty || (endsWithSpace && sentenceEnd)
        default:
            cap = false
        }
        let new: ShiftState = cap ? .on : .off
        if new != shift {
            shift = new
            updateShiftUI()
        }
    }

    // MARK: Apagar com repetição

    private func startDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteCount = 0
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                self?.repeatDelete()
            }
        }
    }

    private func stopDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        autoCap()
        updateSuggestions()
    }

    private func repeatDelete() {
        deleteCount += 1
        if deleteCount > 12 { deleteWord() } else { textDocumentProxy.deleteBackward() }
        clearWordState()
    }

    private func deleteWord() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return }
        var count = 0
        var seenWord = false
        for ch in before.reversed() {
            if ch.isWhitespace || ch.isPunctuation {
                if seenWord { break }
            } else {
                seenWord = true
            }
            count += 1
        }
        for _ in 0..<max(count, 1) { textDocumentProxy.deleteBackward() }
    }

    // MARK: Acentos (segurar a tecla)

    private func showAlternates(for touch: UITouch) {
        guard var a = active[touch], !a.committed, !a.swiping, case .char(let base) = a.key.kind else { return }
        let upper = shift != .off && currentLayer == .letters
        popupOptions = ([base] + a.key.alternates).map { upper ? $0.uppercased() : $0 }

        let keyFrame = a.key.convert(a.key.bounds, to: view)
        let cellW = max(keyFrame.width, 30)
        let h = keyFrame.height
        let width = cellW * CGFloat(popupOptions.count)
        var x = keyFrame.minX
        x = min(max(2, x), view.bounds.width - width - 2)
        let y = max(0, keyFrame.minY - h - 6)
        popupFrame = CGRect(x: x, y: y, width: width, height: h)

        let box = UIView(frame: popupFrame)
        box.backgroundColor = KeyView.normalColor
        box.layer.cornerRadius = 9
        box.layer.shadowColor = UIColor.black.cgColor
        box.layer.shadowOpacity = 0.35
        box.layer.shadowRadius = 4
        box.layer.shadowOffset = CGSize(width: 0, height: 2)
        popupLabels = popupOptions.enumerated().map { i, s in
            let l = UILabel(frame: CGRect(x: CGFloat(i) * cellW + 2, y: 2, width: cellW - 4, height: h - 4))
            l.text = s
            l.textAlignment = .center
            l.font = .systemFont(ofSize: CGFloat(settings.fontSize))
            l.layer.cornerRadius = 7
            l.clipsToBounds = true
            box.addSubview(l)
            return l
        }
        view.addSubview(box)
        popup = box

        let initial = popupOptions.count > 1 ? 1 : 0
        a.popupIndex = initial
        highlightPopup(initial)
        active[touch] = a
        if settings.haptics && hasFullAccess { haptic.impactOccurred() }
    }

    private func popupIndex(at p: CGPoint) -> Int {
        let cellW = popupFrame.width / CGFloat(max(popupOptions.count, 1))
        let i = Int((p.x - popupFrame.minX) / cellW)
        return min(max(i, 0), max(popupOptions.count - 1, 0))
    }

    private func highlightPopup(_ i: Int) {
        for (j, l) in popupLabels.enumerated() {
            l.backgroundColor = j == i ? .systemBlue : .clear
            l.textColor = j == i ? .white : .label
        }
    }

    private func hidePopup() {
        popup?.removeFromSuperview()
        popup = nil
        popupLabels = []
        popupOptions = []
    }

    // MARK: Vibração e som

    private func feedback(_ kind: KeyKind) {
        guard hasFullAccess else { return }
        if settings.haptics {
            haptic.impactOccurred()
            haptic.prepare()
        }
        if settings.clicks {
            let sound: SystemSoundID
            switch kind {
            case .delete: sound = 1155
            case .char, .space: sound = 1104
            default: sound = 1156
            }
            AudioServicesPlaySystemSound(sound)
        }
    }
}
