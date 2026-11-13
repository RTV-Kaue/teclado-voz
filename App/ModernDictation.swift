import Foundation
import AVFoundation
import Speech

/// Ditado com o motor novo do iOS 26 (DictationTranscriber): coloca pontuação sozinho
/// e roda no aparelho, sem limite de tempo.
@available(iOS 26.0, *)
final class ModernDictation {
    var onPartial: ((String) -> Void)?
    var onFinish: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var finished = false

    private static let locale = Locale(identifier: "pt-BR")

    private static func makeTranscriber() -> DictationTranscriber {
        DictationTranscriber(locale: locale,
                             contentHints: [],
                             transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults],
                             attributeOptions: [])
    }

    /// Baixa o modelo de português se ainda não estiver no aparelho
    static func prepare() async -> Bool {
        let supported = await DictationTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == "pt-BR" }) else { return false }
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()]) {
                try await req.downloadAndInstall()
            }
            return true
        } catch {
            return false
        }
    }

    func start() async throws {
        let t = Self.makeTranscriber()
        let a = SpeechAnalyzer(modules: [t])
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        transcriber = t
        analyzer = a
        analyzerFormat = fmt
        continuation = cont
        finalized = ""
        volatile = ""
        finished = false
        lock.unlock()

        resultsTask = Task { [weak self] in
            do {
                for try await r in t.results {
                    let text = String(r.text.characters)
                    let isFinal = r.isFinal
                    await MainActor.run { self?.handle(text, isFinal: isFinal) }
                }
            } catch {
                await MainActor.run { self?.onError?(error.localizedDescription) }
            }
            await MainActor.run { self?.complete() }
        }
        try await a.start(inputSequence: stream)
    }

    /// Chamado na thread de áudio com cada pedaço do microfone
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let cont = continuation
        let fmt = analyzerFormat
        lock.unlock()
        guard let cont else { return }
        guard let fmt, buffer.format != fmt else {
            cont.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != fmt {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil && out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() {
        lock.lock()
        let cont = continuation
        let a = analyzer
        continuation = nil
        lock.unlock()
        cont?.finish()
        Task {
            try? await a?.finalizeAndFinishThroughEndOfInput()
        }
    }

    func cancel() {
        lock.lock()
        let cont = continuation
        let a = analyzer
        continuation = nil
        finished = true
        lock.unlock()
        cont?.finish()
        resultsTask?.cancel()
        Task { await a?.cancelAndFinishNow() }
    }

    private func handle(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        onPartial?(Self.join(finalized, volatile))
    }

    private static func join(_ a: String, _ b0: String) -> String {
        if a.isEmpty { return b0 }
        if b0.isEmpty { return a }
        // O motor começa cada trecho com maiúscula; no meio da frase isso fica errado
        var b = b0
        let prevEnd = a.trimmingCharacters(in: .whitespaces).last
        let chars = Array(b.trimmingCharacters(in: .whitespaces))
        if let p = prevEnd, !".!?".contains(p), chars.count > 1, chars[0].isUppercase, chars[1].isLowercase {
            let trimmed = b.trimmingCharacters(in: .whitespaces)
            b = trimmed.prefix(1).lowercased() + trimmed.dropFirst()
        }
        if a.hasSuffix(" ") || b.hasPrefix(" ") { return a + b }
        return a + " " + b
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        let text = Self.join(finalized, volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        onFinish?(text)
    }
}
