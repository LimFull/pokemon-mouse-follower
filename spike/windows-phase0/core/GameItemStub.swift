// Phase 0 spike: the logic half of GameItem (Items.swift) without the
// CGContext icon drawing — exactly the split planned as ItemCatalog.swift (W2/Phase 5).

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

    var ballBonus: Double {
        switch self {
        case .pokeBall: return 1.0
        case .greatBall: return 1.5
        default: return 0
        }
    }

    var healAmount: Int {
        switch self {
        case .potion: return 20
        case .superPotion: return 50
        default: return 0
        }
    }

    var curesStatus: Bool { self == .fullHeal }

    var isEvolutionItem: Bool { GameItem.stoneEosIds[self] != nil || self == .linkCord || self == .friendCandy }

    static let stoneEosIds: [GameItem: Int] = [
        .fireStone: 146, .thunderStone: 141, .waterStone: 147,
        .leafStone: 149, .moonStone: 145, .sunStone: 144,
    ]
}
