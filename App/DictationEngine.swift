import Foundation
import AVFoundation
import Speech

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
            self?.request?.append(buffer)
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

    func startDictation() {
        guard startSession() else { return }
        guard !recording else { return }
        settings = KeyboardSettings.load()
        guard let recognizer, recognizer.isAvailable else {
            publish(status: "Reconhecimento de voz indisponível agora")
            return
        }
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if settings.preferOffline && recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        req.contextualStrings = Array(settings.vocabulary.filter { !$0.isEmpty }.prefix(100))

        generation += 1
        let gen = generation
        delivered = false
        partial = ""
        request = req
        recording = true
        lastActivity = Date()
        publish(status: "Ouvindo…")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(gen: gen, result: result, error: error) }
        }
    }

    func stopDictation() {
        guard recording else { return }
        recording = false
        request?.endAudio()
        request = nil
        publish(status: "Processando…")
        let gen = generation
        fallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, !self.delivered else { return }
            if self.partial.isEmpty { self.finishWithoutText() } else { self.deliver(self.partial) }
            self.task?.cancel()
        }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func cancelDictation() {
        generation += 1
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
        let text = TextProcessor.process(raw, settings: settings)
        lastResult = text
        partial = ""
        lastActivity = Date()
        if let d = Shared.defaults {
            d.set(text, forKey: K.result)
            d.set(d.integer(forKey: K.resultID) + 1, forKey: K.resultID)
            d.set(Date().timeIntervalSince1970, forKey: K.resultTime)
        }
        DarwinNote.post(DarwinNote.result)
        publish(status: "Sessão ativa")
    }

    private func finishWithoutText() {
        delivered = true
        recording = false
        request = nil
        task = nil
        partial = ""
        publish(status: "Nada reconhecido. Sessão ativa")
    }

    private func publish(status s: String) {
        status = s
        if let d = Shared.defaults {
            d.set(recording, forKey: K.recording)
            d.set(partial, forKey: K.partial)
            d.set(s, forKey: K.status)
        }
        DarwinNote.post(DarwinNote.state)
    }
}
