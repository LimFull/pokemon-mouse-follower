// Phase 0 spike: PartyState references the live BattleController (AppKit) for
// mid-battle gating. Finding for Phase 1: this coupling needs a protocol seam
// (Core-side "LiveBattleBridge") so PartyState stays platform-neutral.

import Foundation

final class BattleController {
    static var current: BattleController? = nil
    func requestRecall() -> Bool { false }
    func cancelRecallRequest() {}
    func requestItem(_ item: GameItem) -> Bool { false }
    var itemPending: Bool { false }
    var playerGaugeFraction: Double? { nil }
    var playerLiveStatus: String? { nil }
}
