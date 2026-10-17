// Owns the current glasses screen and every send to the display. The phone is the
// single source of truth: each send replaces the whole screen, so sends are serialized and only
// the newest pending screen is ever sent.

import Foundation
import MWDATDisplay

final class GlassesRouter {
    enum Action: Sendable {
        case scan
        case retry
        case back
        case history
        case settings
        case newer
        case older
        case resend
        case setting(GlassesScreen.SettingRow)
    }

    private(set) var screen: GlassesScreen = .main(GlassesScreen.Main())
    var onAction: ((Action) -> Void)?

    private let log: EventLog
    private var display: Display?
    private var pending: GlassesScreen?
    private var isSending = false

    init(log: EventLog) {
        self.log = log
    }

    /// The display (re)started: show the current screen again (glasses keep no app state).
    func attach(_ display: Display) {
        self.display = display
        enqueue(screen)
    }

    func detach() {
        display = nil
        pending = nil
    }

    func show(_ screen: GlassesScreen) {
        self.screen = screen
        enqueue(screen)
    }

    /// The tick effect: outline checkmark, then filled 120 ms later. Returns after frame 2.
    func showDoneWithTick(_ done: GlassesScreen.Done) async {
        show(.done(done, filled: false))
        try? await Task.sleep(for: .milliseconds(120))
        show(.done(done, filled: true))
    }

    /// LINKED with the same tick effect as DONE.
    func showLinkedWithTick(_ name: String) async {
        show(.linked(name: name, filled: false))
        try? await Task.sleep(for: .milliseconds(120))
        show(.linked(name: name, filled: true))
    }

    var isOnMain: Bool {
        if case .main = screen { true } else { false }
    }

    // MARK: - Sending

    private func enqueue(_ screen: GlassesScreen) {
        pending = screen
        guard !isSending, display != nil else { return }
        isSending = true
        Task {
            while let next = pending, let display {
                pending = nil
                do {
                    try await send(next, to: display)
                } catch {
                    log.add("display send failed: \(error)")
                }
            }
            isSending = false
        }
    }

    private func send(_ screen: GlassesScreen, to display: Display) async throws {
        switch screen {
        case .main(let model):
            try await display.send(GlassesScreens.main(model, actions: actions))
        case .scanning(let model):
            try await display.send(GlassesScreens.scanning(model))
        case .done(let model, let filled):
            try await display.send(GlassesScreens.done(model, filled: filled))
        case .error(let code, let elapsed):
            try await display.send(GlassesScreens.error(code, elapsed: elapsed, onRetry: action(.retry), onBack: action(.back)))
        case .linked(let name, let filled):
            try await display.send(GlassesScreens.linked(name, filled: filled))
        case .history(let model):
            try await display.send(GlassesScreens.history(model, actions: actions))
        case .settings(let model):
            try await display.send(GlassesScreens.settings(model, actions: actions))
        case .pairInfo:
            try await display.send(GlassesScreens.pairInfo(actions: actions))
        case .boot:
            try await display.send(GlassesScreens.boot())
        }
    }

    private var actions: GlassesScreens.Actions {
        GlassesScreens.Actions(
            scan: action(.scan), history: action(.history), settings: action(.settings),
            newer: action(.newer), older: action(.older), resend: action(.resend),
            back: action(.back), retry: action(.retry),
            setting: { [weak self] row in Task { @MainActor in self?.onAction?(.setting(row)) } })
    }

    private func action(_ action: Action) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in self?.onAction?(action) }
        }
    }
}
