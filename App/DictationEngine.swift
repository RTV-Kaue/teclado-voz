import Foundation
import AVFoundation
import Speech
import UIKit

/// Mantém o microfone ativo em segundo plano ("sessão") e faz o reconhecimento de voz.
/// O teclado manda comandos (iniciar/parar) por notificações e recebe o texto pelo App Group.
final class DictationEngine: ObservableObject {
    static let shared = DictationEngine()

    @Published private(set) var sessionActive = false
    @Published private(set) var recording = false
    @Published private(set) var partial = ""
    @Published private(set) var lastResult = ""
    @Published private(set) var status = "Sessão inativa"
    @Published private(set) var onDeviceAvailable = false
    @Published private(set) var engineInfo = "verificando…"
    @Published private(set) var lastEngine = "—"
    @Published private(set) var lastPunctuation = "—"

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var generation = 0
    private var delivered = true
    private var heartbeat: Timer?
    private var lastActivity = Date()
    private var fallback: DispatchWorkItem?
    private var settings = KeyboardSettings.load()
    private let observer = DarwinObserver()

    // Motor novo (iOS 26)
    private var modern: AnyObject?
    private var modernReady: Bool?
    private var _feed: ((AVAudioPCMBuffer) -> Void)?
    private var feed: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _feed }
        set { lock.lock(); _feed = newValue; lock.unlock() }
    }

    // Whisper online (Groq)
    private let recorder16k = AudioRecorder16k()
    private var _capture = false
    private var capture: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _capture }
        set { lock.lock(); _capture = newValue; lock.unlock() }
    }
    private var groqTask: Task<(String?, String), Never>?
    private var onlineEnabled: Bool { settings.onlineWhisper && !GroqWhisper.apiKey.isEmpty }

    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    private init() {
        onDeviceAvailable = recognizer?.supportsOnDeviceRecognition ?? false
        observer.observe(DarwinNote.start) { [weak self] in self?.startDictation() }
        observer.observe(DarwinNote.stop) { [weak self] in self?.stopDictation() }
        observer.observe(DarwinNote.cancel) { [weak self] in self?.cancelDictation() }
        observer.observe(DarwinNote.settings) { [weak self] in self?.settings = KeyboardSettings.load() }
        observer.observe(DarwinNote.endSession) { [weak self] in self?.endSession() }
        if #available(iOS 26.0, *) {
            Task { [weak self] in
                let ok = await ModernDictation.prepare()
                await MainActor.run {
                    self?.modernReady = ok
                    self?.engineInfo = ok ? "novo (iOS 26) pronto" : "novo indisponível, usando o clássico"
                }
            }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                if self.recording { self.stopDictation() }
            } else if self.sessionActive {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.startEngine()
            }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            guard let self, self.sessionActive else { return }
            try? self.startEngine()
        }
    }

    // MARK: Permissões

    func requestPermissions(_ done: @escaping () -> Void) {
        SFSpeechRecognizer.requestAuthorization { _ in
            AVAudioApplication.requestRecordPermission { _ in
                DispatchQueue.main.async { done() }
            }
        }
    }

    // MARK: Sessão

    @discardableResult
    func startSession() -> Bool {
        lastActivity = Date()
        if sessionActive { return true }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try s.setActive(true)
            try startEngine()
        } catch {
            publish(status: "Erro ao iniciar o microfone: \(error.localizedDescription)")
            return false
        }
        sessionActive = true
        startHeartbeat()
        // ao abrir pelo teclado o app ainda está "inativo" (em transição), mas já pode criar o quadro
        if UIApplication.shared.applicationState != .background { LiveActivityController.shared.start() }
        publish(status: "Sessão ativa")
        return true
    }

    func endSession() {
        cancelDictation()
        heartbeat?.invalidate()
        heartbeat = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
        Shared.defaults?.set(0, forKey: K.heartbeat)
        LiveActivityController.shared.end()
        publish(status: "Sessão inativa")
    }

    private func startEngine() throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "TecladoVoz", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microfone sem permissão ou indisponível"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.feed?(buffer)
            if self.capture { self.recorder16k.append(buffer) }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        beat()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    private func beat() {
        Shared.defaults?.set(Date().timeIntervalSince1970, forKey: K.heartbeat)
        if !recording && Date().timeIntervalSince(lastActivity) > settings.sessionMinutes * 60 {
            endSession()
        }
    }

    // MARK: Ditado

    var usingModernEngine: Bool {
        if #available(iOS 26.0, *) { return settings.modernDictation && modernReady == true }
        return false
    }

    func startDictation() {
        guard startSession() else { return }
        guard !recording else { return }
        settings = KeyboardSettings.load()
        groqTask?.cancel()
        groqTask = nil
        if onlineEnabled {
            recorder16k.reset()
            capture = true
        }
        generation += 1
        let gen = generation
        delivered = false
        partial = ""
        recording = true
        lastActivity = Date()
        if #available(iOS 26.0, *), usingModernEngine {
            publish(status: "Ouvindo…")
            startModern(gen: gen)
        } else {
            startLegacy(gen: gen)
        }
    }

    @available(iOS 26.0, *)
    private func startModern(gen: Int) {
        lastEngine = "novo (iOS 26)"
        let m = ModernDictation()
        m.onPartial = { [weak self] text in
            guard let self, gen == self.generation, !self.delivered else { return }
            self.partial = text
            Shared.defaults?.set(text, forKey: K.partial)
            DarwinNote.post(DarwinNote.state)
        }
        m.onFinish = { [weak self] text in
            guard let self, gen == self.generation, !self.delivered else { return }
            self.feed = nil
            self.modern = nil
            if text.isEmpty { self.finishWithoutText() } else { self.deliver(text) }
        }
        modern = m
        Task { [weak self] in
            do {
                try await m.start()
                await MainActor.run {
                    guard let self, gen == self.generation, self.recording else { return }
                    self.feed = { [weak m] buffer in m?.append(buffer) }
                }
            } catch {
                // Se o motor novo falhar, usa o clássico
                await MainActor.run {
                    guard let self, gen == self.generation, self.recording else { return }
                    self.modern = nil
                    self.startLegacy(gen: gen)
                    self.lastEngine = "clássico (o novo falhou: \(error.localizedDescription))"
                }
            }
        }
    }

    private func startLegacy(gen: Int) {
        guard let recognizer, recognizer.isAvailable else {
            recording = false
            delivered = true
            publish(status: "Reconhecimento de voz indisponível agora")
            return
        }
        task?.cancel()
        if !lastEngine.hasPrefix("clássico (o novo") { lastEngine = "clássico" }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if settings.preferOffline && recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        req.contextualStrings = Array(settings.vocabulary.filter { !$0.isEmpty }.prefix(100))
        request = req
        publish(status: "Ouvindo…")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(gen: gen, result: result, error: error) }
        }
    }

    func stopDictation() {
        guard recording else { return }
        capture = false
        if onlineEnabled && recorder16k.seconds > 0.4 {
            let wav = GroqWhisper.wav(from: recorder16k.take())
            let words = settings.vocabulary.filter { !$0.isEmpty }.prefix(40).joined(separator: ", ")
            let prompt = "Transcrição em português do Brasil, com pontuação correta: vírgulas, pontos e pontos de interrogação." + (words.isEmpty ? "" : " Termos: \(words).")
            groqTask = Task { await GroqWhisper.transcribe(wav: wav, prompt: prompt) }
        }
        recording = false
        request?.endAudio()
        request = nil
        feed = nil
        if #available(iOS 26.0, *), let m = modern as? ModernDictation { m.stop() }
        publish(status: "Processando…")
        let gen = generation
        fallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, !self.delivered else { return }
            if self.partial.isEmpty { self.finishWithoutText() } else { self.deliver(self.partial) }
            self.task?.cancel()
        }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func cancelDictation() {
        generation += 1
        capture = false
        groqTask?.cancel()
        groqTask = nil
        feed = nil
        if #available(iOS 26.0, *), let m = modern as? ModernDictation { m.cancel() }
        modern = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        recording = false
        delivered = true
        partial = ""
        publish(status: sessionActive ? "Sessão ativa" : "Sessão inativa")
    }

    private func handle(gen: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        guard gen == generation, !delivered else { return }
        if let result {
            partial = result.bestTranscription.formattedString
            Shared.defaults?.set(partial, forKey: K.partial)
            DarwinNote.post(DarwinNote.state)
            if result.isFinal { deliver(partial); return }
        }
        if error != nil {
            if partial.isEmpty { finishWithoutText() } else { deliver(partial) }
        }
    }

    private func deliver(_ raw: String) {
        delivered = true
        recording = false
        request = nil
        task = nil
        feed = nil
        let gen = generation
        if let gt = groqTask {
            groqTask = nil
            publish(status: "Transcrevendo online…")
            Task { [weak self] in
                let (online, why) = await gt.value
                await MainActor.run {
                    guard let self, gen == self.generation else { return }
                    if let online {
                        let text = TextProcessor.process(online, settings: self.settings)
                        self.setDiag(why)
                        self.finishDelivery(Punctuator.heuristic(text), needsAI: false, source: "online")
                    } else if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.setDiag("nada reconhecido (\(why))")
                        self.publish(status: "Nada reconhecido. Sessão ativa")
                    } else {
                        self.deliverLocal(raw, note: why)
                    }
                }
            }
            return
        }
        deliverLocal(raw, note: nil)
    }

    /// Pontuação sem internet: IA do iPhone ou regras simples
    private func deliverLocal(_ raw: String, note: String?) {
        let gen = generation
        let suffix = note.map { " — online falhou: \($0)" } ?? ""
        let text = TextProcessor.process(raw, settings: settings)
        let wantsAI = settings.aiPunctuation && Punctuator.aiAvailable && !Punctuator.hasPunctuation(text)
        if wantsAI && UIApplication.shared.applicationState == .active {
            // App na tela: ele mesmo pontua
            publish(status: "Pontuando…")
            Task { [weak self] in
                let (ai, why) = await Punctuator.punctuateWithAI(text)
                await MainActor.run {
                    guard let self, gen == self.generation else { return }
                    self.setDiag((ai != nil ? why : "regras simples (\(why))") + suffix)
                    self.finishDelivery(ai ?? Punctuator.heuristic(text), needsAI: false, source: ai != nil ? "ai" : "rules")
                }
            }
        } else if wantsAI {
            // App em segundo plano: o teclado (que está na tela) pontua
            if !suffix.isEmpty { Shared.defaults?.set("online falhou: \(note ?? "")", forKey: K.diagPunct) }
            finishDelivery(text, needsAI: true, source: "ai")
        } else {
            setDiag((Punctuator.hasPunctuation(text) ? "do próprio motor de voz" : "regras simples") + suffix)
            finishDelivery(Punctuator.heuristic(text), needsAI: false, source: "rules")
        }
    }

    private func setDiag(_ s: String) {
        lastPunctuation = s
        Shared.defaults?.set(s, forKey: K.diagPunct)
    }

    private func finishDelivery(_ text: String, needsAI: Bool, source: String) {
        lastResult = text
        partial = ""
        lastActivity = Date()
        if let d = Shared.defaults {
            d.set(text, forKey: K.result)
            d.set(needsAI, forKey: K.needsAI)
            d.set(source, forKey: K.lastSource)
            d.set(d.integer(forKey: K.resultID) + 1, forKey: K.resultID)
            d.set(Date().timeIntervalSince1970, forKey: K.resultTime)
        }
        DarwinNote.post(DarwinNote.result)
        publish(status: "Sessão ativa")
    }

    func reloadDiag() {
        lastPunctuation = Shared.defaults?.string(forKey: K.diagPunct) ?? "—"
    }

    private func finishWithoutText() {
        if groqTask != nil {
            deliver("")
            return
        }
        delivered = true
        recording = false
        request = nil
        task = nil
        partial = ""
        publish(status: "Nada reconhecido. Sessão ativa")
    }

    private func publish(status s: String) {
        status = s
        let phase: String
        if recording {
            phase = "gravando"
        } else if s == "Transcrevendo online…" || (s == "Processando…" && groqTask != nil) {
            phase = "online"
        } else if s == "Processando…" || s == "Pontuando…" {
            phase = "local"
        } else {
            phase = ""
        }
        if let d = Shared.defaults {
            d.set(recording, forKey: K.recording)
            d.set(partial, forKey: K.partial)
            d.set(s, forKey: K.status)
            d.set(phase, forKey: K.phase)
        }
        if sessionActive { LiveActivityController.shared.update(phase.isEmpty ? "pronto" : phase) }
        DarwinNote.post(DarwinNote.state)
    }
}
