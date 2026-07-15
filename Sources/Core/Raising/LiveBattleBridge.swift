// Seam between the platform-neutral party state and the live battle playback
// (Phase 0 finding, design/windows-port.md §10): PartyState gates mid-battle
// recalls/items on the running battle, which is a platform-layer concern.
// Each platform's battle controller conforms and registers itself here.

import Foundation

protocol LiveBattleBridge: AnyObject {
    /// Ask the running battle to break off at the next turn boundary.
    /// Returns false when no battle is running (recall applies immediately).
    func requestRecall() -> Bool
    func cancelRecallRequest()
    /// Ask the running battle to swap the active mon for the member at
    /// `index` once the turn in progress fully plays out (mainline switch
    /// timing). Returns false when no battle is running (the switch applies
    /// immediately) or the target can't come in (fainted / already active).
    func requestSwitch(to index: Int) -> Bool
    /// The party index a deferred mid-battle switch is waiting to send out
    /// (nil = no switch pending). Panels show the queued state with it.
    var switchPendingIndex: Int? { get }
    /// Queue a healing/status item as the follower's next battle action.
    /// Returns false when no battle is running (apply to the saved state).
    func requestItem(_ item: GameItem) -> Bool
    var itemPending: Bool { get }
    /// Queue a manual ball throw as the follower's next battle action
    /// (bag "던지기" button). Returns false when no battle is running.
    func requestBall(_ item: GameItem) -> Bool
    var ballPending: Bool { get }
    /// Live HP fraction of the player's mon while a battle plays (nil otherwise).
    var playerGaugeFraction: Double? { get }
    /// Live major-status of the player's mon while a battle plays (nil otherwise).
    var playerLiveStatus: String? { get }
}

enum LiveBattle {
    static weak var current: (any LiveBattleBridge)?
}
