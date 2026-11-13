import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var engine: DictationEngine
    @Binding var showReturnHint: Bool
    @State private var settings = KeyboardSettings.load()
    @State private var testText = ""

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
                    Toggle("Motor novo com pontuação (iOS 26)", isOn: $settings.modernDictation)
                    Toggle("Pontuar com a IA do iPhone", isOn: $settings.aiPunctuation)
                    Toggle("Preferir reconhecimento offline", isOn: $settings.preferOffline)
                    sliderRow("Sessão fica ativa por", value: $settings.sessionMinutes, range: 1...60, unit: "min")
                } header: {
                    Text("Reconhecimento")
                } footer: {
                    Text(engine.onDeviceAvailable
                         ? "Reconhecimento offline em português disponível neste iPhone."
                         : "Reconhecimento offline em português indisponível; será usado o online da Apple (gratuito).")
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
                    Button("Esquecer palavras aprendidas", role: .destructive) {
                        Shared.defaults?.removeObject(forKey: K.learned)
                        DarwinNote.post(DarwinNote.settings)
                    }
                } footer: {
                    Text("Quando você apaga logo depois de uma correção, o teclado volta a palavra original e aprende ela.")
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
            .onAppear { engine.requestPermissions {} }
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
