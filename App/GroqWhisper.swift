import Foundation
import AVFoundation

/// Transcrição online com o Whisper (via Groq, plano gratuito).
/// O Whisper já devolve o texto com pontuação. Só é usado se houver chave e internet.
enum GroqWhisper {
    static let keyName = "groq.key"

    static var apiKey: String {
        (UserDefaults.standard.string(forKey: keyName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frases que o Whisper costuma "inventar" quando só tem silêncio
    private static let hallucinations = ["legendas pela comunidade amara.org", "obrigado.", "obrigada.",
                                         "tchau.", "legenda adriana zanotto", "e aí", "...", "."]

    static func transcribe(wav: Data, prompt: String) async -> (String?, String) {
        let key = apiKey
        guard !key.isEmpty else { return (nil, "sem chave da Groq") }
        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else { return (nil, "url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3")
        field("language", "pt")
        field("response_format", "json")
        field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 401 { return (nil, "chave da Groq inválida") }
                if code == 429 { return (nil, "limite gratuito da Groq atingido") }
                return (nil, "Groq respondeu erro \(code)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else { return (nil, "resposta estranha da Groq") }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || hallucinations.contains(t.lowercased()) { return (nil, "Groq não ouviu nada") }
            return (t, "Whisper online (Groq)")
        } catch {
            return (nil, "sem internet ou Groq fora do ar")
        }
    }

    /// Monta um arquivo WAV (16 kHz, mono, 16 bits) a partir do áudio gravado
    static func wav(from pcm: Data, sampleRate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// Guarda o áudio do ditado em 16 kHz mono para mandar ao Whisper
final class AudioRecorder16k {
    private let lock = NSLock()
    private var data = Data()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func reset() {
        lock.lock(); data = Data(); lock.unlock()
    }

    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        let d = data
        data = Data()
        return d
    }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(data.count) / 32000
    }

    /// Chamado na thread de áudio
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        lock.lock()
        if data.count < 20_000_000 { data.append(bytes) }
        lock.unlock()
    }
}
