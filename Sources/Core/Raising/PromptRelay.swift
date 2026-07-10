// Raising mode — on-overlay decision prompts, platform-neutral half
// (design C1 / #5 / #14 / D14). The battle playback enqueues prompts here;
// each platform's UI (macOS PromptCenter, Windows Phase 5b) registers a
// handler at startup. Without a handler prompts are dropped — the pending
// decision is re-derivable from the save (pendingMoves re-fire on the next
// level-up; an unresolved capture is simply not kept), so a headless run
// never wedges.

import Foundation

enum OverlayPrompt {
    case learnMove(monIndex: Int, moveId: Int)
    case fullParty(captured: OwnedPokemon)
}

enum PromptRelay {
    /// Set by the platform UI at startup (macOS: PromptCenter.shared.enqueue).
    static var handler: ((OverlayPrompt) -> Void)?

    static func enqueue(_ prompt: OverlayPrompt) {
        handler?(prompt)
    }
}
