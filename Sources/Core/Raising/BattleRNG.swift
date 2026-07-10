// Battle-engine randomness source (design/windows-port.md W18-②). The engine
// draws every roll from this generator so a fixed seed replays a battle
// bit-identically on both platforms — the cross-OS parity fixture
// (--dump-parity) relies on it. Default-seeded from system entropy, so normal
// play stays as unpredictable as the stdlib generator it replaces.

import Foundation

/// SplitMix64 — tiny, fast, and identical everywhere by construction.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum BattleRNG {
    static var g: SplitMix64 = {
        var entropy = SystemRandomNumberGenerator()
        return SplitMix64(seed: entropy.next())
    }()

    /// Deterministic mode for the parity fixture / tests.
    static func reseed(_ seed: UInt64) { g = SplitMix64(seed: seed) }
}
