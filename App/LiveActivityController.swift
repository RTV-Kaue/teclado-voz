import Foundation
import ActivityKit

/// Mostra a sessão do microfone na tela bloqueada e na Dynamic Island
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<RecordingAttributes>?
    private var phase = ""

    /// Só pode ser chamado com o app na tela (regra do iOS)
    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { update("pronto"); return }
        let old = Activity<RecordingAttributes>.activities
        Task { for a in old { await a.end(nil, dismissalPolicy: .immediate) } }
        let state = RecordingAttributes.ContentState(phase: "pronto", since: Date())
        do {
            activity = try Activity.request(attributes: RecordingAttributes(),
                                            content: .init(state: state, staleDate: nil),
                                            pushType: nil)
            phase = "pronto"
        } catch {
            activity = nil
        }
    }

    func update(_ newPhase: String) {
        guard let a = activity, newPhase != phase else { return }
        phase = newPhase
        let state = RecordingAttributes.ContentState(phase: newPhase, since: Date())
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        phase = ""
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
