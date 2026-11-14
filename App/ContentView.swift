import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var engine: DictationEngine
    @Binding var showReturnHint: Bool
    @State private var settings = KeyboardSettings.load()
    @State private var testText = ""
    @State private var groqKey = GroqWhisper.apiKey

    var body: some View {
        NavigationStack {
            Form {
                if showReturnHint && engine.sessionActive {
                    Section {
                        Label("Pronto! Toque em ◀ no canto superior esquerdo da tela para voltar ao app onde você estava.",
                              systemImage: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }

                Section("Ditado") {
                    LabeledContent("Status", value: engine.status)
                    if !engine.partial.isEmpty {
                        Text(engine.partial).foregroundStyle(.secondary)
                    }
                    if !engine.lastResult.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Último resultado").font(.caption).foregroundStyle(.secondary)
                            Text(engine.lastResult).textSelection(.enabled)
                        }
                    }
                    Button(engine.recording ? "Parar ditado de teste" : "Ditado de teste") {
                        if engine.recording {
                            engine.stopDictation()
                        } else {
                            engine.requestPermissions { engine.startDictation() }
                        }
                    }
                    Button(engine.sessionActive ? "Encerrar sessão" : "Iniciar sessão") {
                        if engine.sessionActive {
                            engine.endSession()
                        } else {
                            engine.requestPermissions { engine.startSession() }
                        }
                    }
                    .foregroundStyle(engine.sessionActive ? Color.red : Color.accentColor)
                }

                Section {
                    sliderRow("Altura das teclas", value: $settings.keyHeight, range: 40...80, unit: "pt")
                    sliderRow("Espaço entre teclas", value: $settings.keySpacing, range: 2...12, unit: "pt")
                    sliderRow("Tamanho da letra", value: $settings.fontSize, range: 16...32, unit: "pt")
                    Toggle("Correção automática", isOn: $settings.autocorrect)
                    Toggle("Digitar deslizando", isOn: $settings.swipeTyping)
                    Toggle("Vibração ao tocar", isOn: $settings.haptics)
                    Toggle("Som ao tocar", isOn: $settings.clicks)
                } header: {
                    Text("Teclado")
                } footer: {
                    Text("As mudanças aparecem na hora no teclado.")
                }

                Section {
                    Picker("Modo do ditado", selection: $settings.onlineWhisper) {
                        Text("Online").tag(true)
                        Text("Offline").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if settings.onlineWhisper {
                        SecureField("Chave da Groq (gsk_...)", text: $groqKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: groqKey) { _, v in
                                UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GroqWhisper.keyName)
                            }
                        if groqKey.isEmpty {
                            Link("Criar chave grátis em console.groq.com", destination: URL(string: "https://console.groq.com/keys")!)
                        }
                    }
                    sliderRow("Microfone fica pronto por", value: $settings.sessionMinutes, range: 1...60, unit: "min")
                } header: {
                    Text("Modo")
                } footer: {
                    Text(settings.onlineWhisper
                         ? "Online: usa o Whisper (grátis, até 2.000 ditados por dia), que entende melhor e pontua muito bem. Sem internet ou se falhar, usa o iPhone automaticamente."
                         : "Offline: tudo fica no iPhone, sem internet. A pontuação é feita pela IA do iPhone quando disponível.")
                }

                Section("Personalização") {
                    NavigationLink("Vocabulário técnico (\(settings.vocabulary.count))") {
                        VocabularyView(items: $settings.vocabulary)
                    }
                    NavigationLink("Substituições (\(settings.replacements.count))") {
                        ReplacementsView(items: $settings.replacements)
                    }
                }

                Section {
                    NavigationLink("Minhas palavras") { MyWordsView() }
                } footer: {
                    Text("Tocar na palavra entre aspas na barra do teclado ensina a palavra. Segurar uma sugestão permite remover ela do dicionário.")
                }

                Section("Testar o teclado") {
                    TextField("Toque aqui e troque para o Teclado Voz", text: $testText, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Configuração inicial") {
                    Text("1. Ajustes › Geral › Teclado › Teclados › Adicionar Novo Teclado › Teclado Voz\n2. Toque em Teclado Voz e ative “Permitir Acesso Total”\n3. Em qualquer app, segure o 🌐 e escolha Teclado Voz")
                        .font(.callout)
                    Button("Abrir Ajustes") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("Diagnóstico") {
                    LabeledContent("Grupo de app", value: Shared.appGroupID ?? "NÃO ENCONTRADO ⚠️")
                    LabeledContent("Motor de ditado", value: engine.engineInfo)
                    LabeledContent("Último ditado usou", value: engine.lastEngine)
                    LabeledContent("Pontuação do último", value: engine.lastPunctuation)
                    LabeledContent("IA do iPhone", value: Punctuator.aiStatus)
                    LabeledContent("Versão", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                }
            }
            .navigationTitle("Teclado Voz")
            .onChange(of: settings) { _, newValue in newValue.save() }
            .onAppear {
                engine.requestPermissions {}
                engine.reloadDiag()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                engine.reloadDiag()
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue)) \(unit)")
            Slider(value: value, in: range, step: 1)
        }
    }
}

struct VocabularyView: View {
    @Binding var items: [String]
    @State private var newItem = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Novo termo", text: $newItem)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Adicionar", action: add)
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Termos que o reconhecimento de voz deve priorizar (até 100).")
            }
            Section {
                ForEach(items, id: \.self) { Text($0) }
                    .onDelete { items.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Vocabulário")
        .toolbar { EditButton() }
    }

    private func add() {
        let t = newItem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !items.contains(t) else { return }
        items.insert(t, at: 0)
        newItem = ""
    }
}

struct ReplacementsView: View {
    @Binding var items: [Replacement]
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        List {
            Section {
                TextField("Ouvido (ex.: pick up)", text: $from)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Escrever (ex.: pickup)", text: $to)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Adicionar") {
                    let f = from.trimmingCharacters(in: .whitespaces)
                    guard !f.isEmpty else { return }
                    items.insert(Replacement(from: f, to: to), at: 0)
                    from = ""; to = ""
                }
            } header: {
                Text("Nova substituição")
            } footer: {
                Text("Quando o ditado tiver o texto da esquerda, ele vira o da direita. Use \\n para quebra de linha.")
            }
            Section {
                ForEach($items) { $item in
                    HStack {
                        TextField("ouvido", text: $item.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("escrever", text: $item.to)
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
                .onDelete { items.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Substituições")
        .toolbar { EditButton() }
    }
}

struct MyWordsView: View {
    @State private var learned: [String] = Shared.defaults?.stringArray(forKey: K.learned) ?? []
    @State private var blocked: [String] = Shared.defaults?.stringArray(forKey: K.blocked) ?? []

    var body: some View {
        List {
            Section {
                if learned.isEmpty { Text("Nenhuma ainda").foregroundStyle(.secondary) }
                ForEach(learned, id: \.self) { Text($0) }
                    .onDelete { learned.remove(atOffsets: $0); save() }
            } header: {
                Text("Aprendidas (\(learned.count))")
            } footer: {
                Text("Deslize para a esquerda para apagar uma palavra aprendida errada.")
            }
            Section {
                if blocked.isEmpty { Text("Nenhuma").foregroundStyle(.secondary) }
                ForEach(blocked, id: \.self) { Text($0) }
                    .onDelete { blocked.remove(atOffsets: $0); save() }
            } header: {
                Text("Removidas do dicionário (\(blocked.count))")
            } footer: {
                Text("Deslize para devolver a palavra ao dicionário.")
            }
            Section {
                Button("Esquecer as previsões aprendidas", role: .destructive) {
                    Shared.defaults?.removeObject(forKey: "user.bigrams")
                    DarwinNote.post(DarwinNote.settings)
                }
            } footer: {
                Text("O teclado aprende quais palavras você costuma escrever em sequência para prever a próxima.")
            }
        }
        .navigationTitle("Minhas palavras")
        .toolbar { EditButton() }
    }

    private func save() {
        Shared.defaults?.set(learned, forKey: K.learned)
        Shared.defaults?.set(blocked, forKey: K.blocked)
        DarwinNote.post(DarwinNote.settings)
    }
}
