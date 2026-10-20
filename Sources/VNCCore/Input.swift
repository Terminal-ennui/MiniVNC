import CoreGraphics

/// Remembers the keysym each held key sent, so releases match presses and nothing sticks on the remote.
public struct KeyTracker {
    private var held: [UInt16: UInt32] = [:]

    public init() {}

    public func isHeld(_ keyCode: UInt16) -> Bool { held[keyCode] != nil }

    public mutating func press(_ keyCode: UInt16, keysym: UInt32) {
        held[keyCode] = keysym
    }

    /// The keysym to release, or nil if the key wasn't held or another held key still sends the same keysym (e.g. ⌘ and ⌃).
    public mutating func release(_ keyCode: UInt16) -> UInt32? {
        guard let keysym = held.removeValue(forKey: keyCode) else { return nil }
        return held.values.contains(keysym) ? nil : keysym
    }

    /// Every held keysym once, ordinary keys before modifiers.
    public mutating func releaseAll() -> [UInt32] {
        defer { held.removeAll() }
        let keysyms = Array(Set(held.values))
        return keysyms.filter { !Self.isModifier($0) } + keysyms.filter(Self.isModifier)
    }

    /// Releases ordinary keys but keeps modifiers held. AppKit stops delivering keyUp once ⌘ goes down,
    /// so keys still held at that point would otherwise stay down on the remote.
    public mutating func releaseNonModifiers() -> [UInt32] {
        let released = held.filter { !Self.isModifier($0.value) }
        for keyCode in released.keys { held[keyCode] = nil }
        return Array(Set(released.values))
    }

    /// Shift_L … Hyper_R.
    private static func isModifier(_ keysym: UInt32) -> Bool { (0xFFE1...0xFFEE).contains(keysym) }
}

/// Turns AppKit scroll deltas into RFB wheel "button" clicks: 4 up, 5 down, 6 left, 7 right.
public struct ScrollAccumulator {
    public static let pointsPerClick: CGFloat = 16
    private var pending = CGPoint.zero

    public init() {}

    /// Positive dy scrolls up, positive dx scrolls left. Precise (trackpad) deltas are points and accumulate;
    /// line deltas give one click per line, at least one for any movement. Returns one button bit per click.
    public mutating func clicks(dx: CGFloat, dy: CGFloat, precise: Bool) -> [UInt8] {
        let vertical: Int, horizontal: Int
        if precise {
            pending.x += dx
            pending.y += dy
            vertical = Int(pending.y / Self.pointsPerClick)
            horizontal = Int(pending.x / Self.pointsPerClick)
            pending.y -= CGFloat(vertical) * Self.pointsPerClick
            pending.x -= CGFloat(horizontal) * Self.pointsPerClick
        } else {
            vertical = Self.lines(dy)
            horizontal = Self.lines(dx)
        }
        return Array(repeating: vertical > 0 ? 1 << 3 : 1 << 4, count: abs(vertical))
            + Array(repeating: horizontal > 0 ? 1 << 5 : 1 << 6, count: abs(horizontal))
    }

    private static func lines(_ delta: CGFloat) -> Int {
        guard delta != 0 else { return 0 }
        let count = max(1, Int(abs(delta).rounded()))
        return delta > 0 ? count : -count
    }
}
