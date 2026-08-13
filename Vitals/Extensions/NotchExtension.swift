import Foundation

/// A condition that accompanies the state already occupying the notch instead
/// of replacing it. Its owner supplies the lifecycle; Vitals only remembers
/// when that lifecycle began so simultaneous Extensions keep a stable order.
struct NotchExtension: Equatable, Identifiable {
    var id: String
    var name: String
    var startedAt: Date

    var symbol: String {
        switch name.lowercased() {
        case "claude": "sparkles"
        case "vpn": "lock.shield.fill"
        default: "puzzlepiece.extension.fill"
        }
    }
}

/// The two outboard slots after active Extensions have been ordered. The first
/// condition to become active gets the preferred right edge; a second takes the
/// left. Rebuilding from timestamps makes the survivor move right when the
/// earlier condition ends without retaining separate slot bookkeeping.
struct ExtensionSlots: Equatable {
    var left: NotchExtension?
    var right: NotchExtension?

    static let empty = ExtensionSlots()

    static func arrange(_ active: [NotchExtension]) -> ExtensionSlots {
        let ordered = active.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }
        return ExtensionSlots(left: ordered.dropFirst().first, right: ordered.first)
    }
}

#if DEBUG
enum NotchExtensionSelfCheck {
    static func run() {
        let first = NotchExtension(
            id: "vpn", name: "vpn", startedAt: Date(timeIntervalSince1970: 1))
        let second = NotchExtension(
            id: "claude", name: "claude", startedAt: Date(timeIntervalSince1970: 2))

        let one = ExtensionSlots.arrange([first])
        precondition(one.right == first && one.left == nil,
                     "The first Extension must take the right slot")

        let two = ExtensionSlots.arrange([second, first])
        precondition(two.right == first && two.left == second,
                     "Activation order, not input order, must allocate slots")

        let survivor = ExtensionSlots.arrange([second])
        precondition(survivor.right == second && survivor.left == nil,
                     "A surviving Extension must return to the right slot")
    }
}
#endif
