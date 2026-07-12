// Raising mode — item catalog: the platform-neutral half of the item system
// (design D12; split per design/windows-port.md W2/Phase 5 preview). The drawn
// icons and the overlay spawner live in the platform layer (macOS Items.swift).

import Foundation

enum GameItem: Int, CaseIterable, Codable {
    case pokeBall = 1, greatBall = 2
    case potion = 10, superPotion = 11, fullHeal = 12
    case revive = 20
    case fireStone = 30, thunderStone = 31, waterStone = 32
    case leafStone = 33, moonStone = 34, sunStone = 35
    case linkCord = 40, friendCandy = 41

    var nameKey: String {
        switch self {
        case .pokeBall: return "item.pokeball"
        case .greatBall: return "item.greatball"
        case .potion: return "item.potion"
        case .superPotion: return "item.superpotion"
        case .fullHeal: return "item.fullheal"
        case .revive: return "item.revive"
        case .fireStone: return "item.firestone"
        case .thunderStone: return "item.thunderstone"
        case .waterStone: return "item.waterstone"
        case .leafStone: return "item.leafstone"
        case .moonStone: return "item.moonstone"
        case .sunStone: return "item.sunstone"
        case .linkCord: return "item.linkcord"
        case .friendCandy: return "item.friendcandy"
        }
    }
    var displayName: String { L(nameKey) }
    /// Bag description ("HP를 50 회복한다." & co) — <nameKey>.desc in strings.
    var desc: String { L(nameKey + ".desc") }
    var isBall: Bool { ballBonus > 0 }

    /// Catch-rate multiplier for balls (0 = not a ball).
    var ballBonus: Double {
        switch self {
        case .pokeBall: return 1.0
        case .greatBall: return 1.5
        default: return 0
        }
    }

    /// HP restored by potions (0 = not a potion).
    var healAmount: Int {
        switch self {
        case .potion: return 20
        case .superPotion: return 50
        default: return 0
        }
    }

    /// Cures every major status ailment (mainline Full Heal; no HP restored).
    var curesStatus: Bool { self == .fullHeal }

    var isEvolutionItem: Bool { GameItem.stoneEosIds[self] != nil || self == .linkCord || self == .friendCandy }

    /// EoS item id each stone corresponds to (evolutions.json ITEMS param1).
    static let stoneEosIds: [GameItem: Int] = [
        .fireStone: 146, .thunderStone: 141, .waterStone: 147,
        .leafStone: 149, .moonStone: 145, .sunStone: 144,
    ]

    /// Spawn weight (relative). Balls/potions common, the rest rare (D12).
    var weight: Int {
        switch self {
        case .pokeBall: return 26
        case .greatBall: return 9
        case .potion: return 24
        case .superPotion: return 9
        case .fullHeal: return 7
        case .revive: return 8
        case .fireStone, .thunderStone, .waterStone, .leafStone, .moonStone, .sunStone: return 2
        case .linkCord: return 5
        case .friendCandy: return 7
        }
    }

    static func randomSpawn() -> GameItem {
        let total = allCases.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<total)
        for item in allCases {
            roll -= item.weight
            if roll < 0 { return item }
        }
        return .pokeBall
    }
}
