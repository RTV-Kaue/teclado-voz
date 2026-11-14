import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct AtividadeBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

private let purple = Color(red: 0.49, green: 0.23, blue: 0.93)
private let blue = Color(red: 0.15, green: 0.39, blue: 0.92)

private func phaseInfo(_ phase: String) -> (title: String, icon: String, color: Color) {
    switch phase {
    case "gravando": return ("Gravando", "waveform", .red)
    case "online": return ("Transcrevendo online", "icloud.and.arrow.up", purple)
    case "local": return ("Processando no iPhone", "iphone", blue)
    default: return ("Microfone pronto", "mic.fill", purple)
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let info = phaseInfo(context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Teclado Voz").font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: info.icon).foregroundStyle(info.color)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == "gravando" {
                        Text(context.state.since, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.red)
                            .frame(maxWidth: 56)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(info.title).font(.headline)
                        Spacer()
                        ActionButton(phase: context.state.phase)
                    }
                }
            } compactLeading: {
                Image(systemName: info.icon).foregroundStyle(info.color)
            } compactTrailing: {
                if context.state.phase == "gravando" {
                    Text(context.state.since, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.red)
                        .frame(maxWidth: 40)
                } else {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: info.icon).foregroundStyle(info.color)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        let info = phaseInfo(state.phase)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(info.color.opacity(0.25)).frame(width: 44, height: 44)
                Image(systemName: info.icon).font(.title3).foregroundStyle(info.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Teclado Voz").font(.caption).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 6) {
                    Text(info.title).font(.headline).foregroundStyle(.white)
                    if state.phase == "gravando" {
                        Text(state.since, style: .timer)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            ActionButton(phase: state.phase)
        }
        .padding(16)
    }
}

private struct ActionButton: View {
    let phase: String

    var body: some View {
        if phase == "gravando" {
            Button(intent: StopRecordingIntent()) {
                Label("Parar", systemImage: "stop.fill")
                    .font(.subheadline.bold())
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        } else {
            Button(intent: EndSessionIntent()) {
                Label("Encerrar", systemImage: "xmark")
                    .font(.subheadline)
            }
            .tint(.white.opacity(0.25))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}
