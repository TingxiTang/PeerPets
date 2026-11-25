import Foundation

enum Companion: CaseIterable { case dragon, cat }

enum HoverResponse { case welcome, familiar, stir }

struct PetReactions {
    private var visits: [Companion:[TimeInterval]] = [:]
    private var enteredAt: TimeInterval = 0
    private var handled = false
    private(set) var target: Companion?
    private(set) var response: HoverResponse?
    private var until: TimeInterval = 0

    mutating func observe(_ pet:Companion?, awake:Bool, allowed:Bool, at time:TimeInterval) {
        if target != pet {
            target = pet
            enteredAt = time
            handled = false
            response = nil
        }
        guard let pet else { return }
        if !allowed {
            handled = true
            response = nil
            return
        }
        if time >= until { response = nil }
        guard !handled, time-enteredAt >= 0.16 else { return }
        handled = true
        var previous = (visits[pet] ?? []).filter { time-$0 < 30 }
        let count = previous.count
        previous.append(time)
        visits[pet] = Array(previous.suffix(3))
        guard count < 2 else { return }
        response = awake ? (count == 0 ? .welcome : .familiar) : .stir
        until = time + (response == .welcome ? 1.25 : 0.55)
    }
}
