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
    private var currentLayer: KeyboardLayer = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var heightConstraint: NSLayoutConstraint?
    private let topBarHeight: CGFloat = 46

    private let topBar = UIView()
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let container = KeysContainer()
    private let rowsStack = UIStackView()

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
    private let observer = DarwinObserver()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settings = KeyboardSettings.load()
        rebuildKeys()
        updateHeight()
        autoCap()
        haptic.prepare()
        insertResultIfNew()
        refreshStatus()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
        stopDeleteRepeat()
        hidePopup()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        autoCap()
        updateReturnKey()
    }

    // MARK: Barra superior (microfone)

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

        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.image = UIImage(systemName: "mic.fill")
        micButton.configuration = cfg
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        for v in [dismissButton, statusLabel, micButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 6),
            dismissButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            dismissButton.heightAnchor.constraint(equalToConstant: 36),
            statusLabel.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            micButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            micButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 84),
            micButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    @objc private func dismissTapped() { dismissKeyboard() }

    @objc private func micTapped() {
        if settings.haptics && hasFullAccess { haptic.impactOccurred() }
        guard hasFullAccess, let d = Shared.defaults else { refreshStatus(); return }
        if Shared.sessionAlive {
            if d.bool(forKey: K.recording) {
                DarwinNote.post(DarwinNote.stop)
                waitingResult = true
                waitingSince = Date()
            } else {
                DarwinNote.post(DarwinNote.start)
            }
        } else if let url = URL(string: "\(Shared.urlScheme)://dictate") {
            if openContainingApp(url) {
                statusLabel.text = "Abrindo o app… depois toque em ◀ para voltar"
                return
            } else {
                statusLabel.text = "Abra o app Teclado Voz para ativar o ditado"
                return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshStatus() }
    }

    private func refreshStatus() {
        var cfg = micButton.configuration ?? .filled()
        let d = Shared.defaults
        let alive = Shared.sessionAlive
        let recording = alive && (d?.bool(forKey: K.recording) ?? false)
        if waitingResult && Date().timeIntervalSince(waitingSince) > 5 { waitingResult = false }

        let text: String
        if !hasFullAccess {
            text = "Ative “Permitir Acesso Total” nos Ajustes"
            cfg.image = UIImage(systemName: "mic.slash")
            cfg.baseBackgroundColor = .systemGray
        } else if d == nil {
            text = "Erro: grupo de app não encontrado"
            cfg.image = UIImage(systemName: "exclamationmark.triangle")
            cfg.baseBackgroundColor = .systemGray
        } else if recording {
            let p = d?.string(forKey: K.partial) ?? ""
            text = p.isEmpty ? "Ouvindo… fale agora" : p
            cfg.image = UIImage(systemName: "stop.fill")
            cfg.baseBackgroundColor = .systemRed
        } else if waitingResult {
            text = "Processando…"
            cfg.image = UIImage(systemName: "ellipsis")
            cfg.baseBackgroundColor = .systemOrange
        } else if alive {
            text = "Pronto: toque no microfone"
            cfg.image = UIImage(systemName: "mic.fill")
            cfg.baseBackgroundColor = .systemBlue
        } else {
            text = "Toque no microfone para ativar o ditado"
            cfg.image = UIImage(systemName: "mic")
            cfg.baseBackgroundColor = .systemGray
        }
        statusLabel.text = text
        micButton.configuration = cfg
    }

    private func insertResultIfNew() {
        guard let d = Shared.defaults else { return }
        let id = d.integer(forKey: K.resultID)
        guard id > d.integer(forKey: K.consumedID) else { return }
        d.set(id, forKey: K.consumedID)
        waitingResult = false
        let age = Date().timeIntervalSince1970 - d.double(forKey: K.resultTime)
        guard age < 30, let raw = d.string(forKey: K.result), !raw.isEmpty else { refreshStatus(); return }
        textDocumentProxy.insertText(adjustForContext(raw))
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
        return false
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
        let unit: KeyView

        switch currentLayer {
        case .letters:
            let r1 = "qwertyuiop".map { charKey(String($0)) }
            let r2 = "asdfghjklç".map { charKey(String($0)) }
            let r3 = "zxcvbnm".map { charKey(String($0)) }
            let shiftK = makeKey(.shift, symbol: "shift", special: true)
            let del = makeKey(.delete, symbol: "delete.left", special: true)
            shiftKey = shiftK
            letterKeys = r1 + r2 + r3
            unit = r1[0]
            rows = [makeRow(r1, equal: true), makeRow(r2, equal: true),
                    makeRow([shiftK] + r3 + [del], equal: false)]
            for k in r3 { k.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true }
            shiftK.widthAnchor.constraint(equalTo: del.widthAnchor).isActive = true

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
            toggle.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.45).isActive = true
            del.widthAnchor.constraint(equalTo: toggle.widthAnchor).isActive = true
            for k in punct.dropFirst() { k.widthAnchor.constraint(equalTo: punct[0].widthAnchor).isActive = true }
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
            globe.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.1).isActive = true
        }
        bottom += [comma, space, period, ret]
        rows.append(makeRow(bottom, equal: false))

        switchKey.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.3).isActive = true
        comma.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true
        period.widthAnchor.constraint(equalTo: unit.widthAnchor).isActive = true
        ret.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: 1.9).isActive = true

        rows.forEach { rowsStack.addArrangedSubview($0) }
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
        for (t, pending) in active where !pending.committed && pending.popupIndex == nil {
            var a = pending
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
            textDocumentProxy.deleteBackward()
            a.committed = true
            startDeleteRepeat()
            autoCap()
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
        if let idx = a.popupIndex {
            if !cancelled, idx < popupOptions.count { insertCharacter(popupOptions[idx], raw: true) }
            hidePopup()
            return
        }
        if !cancelled && !a.committed { commit(a) }
    }

    private func commit(_ a: ActiveTouch) {
        switch a.key.kind {
        case .char(let s):
            insertCharacter(s, raw: false)
        case .space:
            if !a.cursorMoved { spaceTapped() }
        case .ret:
            textDocumentProxy.insertText("\n")
            autoCap()
        case .layer(let l):
            currentLayer = l
            rebuildKeys()
            autoCap()
        case .shift, .delete:
            break
        }
    }

    private func insertCharacter(_ s: String, raw: Bool) {
        let text = (!raw && shift != .off && currentLayer == .letters) ? s.uppercased() : s
        textDocumentProxy.insertText(text)
        if shift == .on {
            shift = .off
            updateShiftUI()
        }
        if currentLayer != .letters && s == "'" {
            currentLayer = .letters
            rebuildKeys()
        }
    }

    private func spaceTapped() {
        let now = Date()
        let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        if now.timeIntervalSince(lastSpaceTap) < 0.4, ctx.hasSuffix(" "),
           let c = ctx.dropLast().last, c.isLetter || c.isNumber {
            // Espaço duplo vira ". "
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceTap = .distantPast
        } else {
            textDocumentProxy.insertText(" ")
            lastSpaceTap = now
        }
        if currentLayer != .letters {
            currentLayer = .letters
            rebuildKeys()
        }
        autoCap()
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
    }

    private func repeatDelete() {
        deleteCount += 1
        if deleteCount > 12 { deleteWord() } else { textDocumentProxy.deleteBackward() }
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
        guard var a = active[touch], !a.committed, case .char(let base) = a.key.kind else { return }
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
        if settings.haptics { haptic.impactOccurred() }
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
