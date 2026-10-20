import CoreGraphics
import Testing
@testable import VNCCore

struct KeyTrackerTests {
    @Test func releaseReturnsTheKeysymThatWasPressed() {
        var keys = KeyTracker()
        keys.press(0, keysym: 0x41)
        #expect(keys.isHeld(0))
        #expect(keys.release(0) == 0x41)
        #expect(!keys.isHeld(0))
        #expect(keys.release(0) == nil)
    }

    @Test func sharedKeysymIsReleasedOnlyWhenLastHolderLetsGo() {
        var keys = KeyTracker()
        keys.press(55, keysym: 0xFFE3) // ⌘ → Control_L
        keys.press(59, keysym: 0xFFE3) // ⌃ → Control_L
        #expect(keys.release(55) == nil)
        #expect(keys.release(59) == 0xFFE3)
    }

    @Test func releaseAllReturnsEachKeysymOnceAndClears() {
        var keys = KeyTracker()
        keys.press(55, keysym: 0xFFE3)
        keys.press(59, keysym: 0xFFE3)
        keys.press(0, keysym: 0x61)
        #expect(Set(keys.releaseAll()) == [0xFFE3, 0x61])
        #expect(keys.releaseAll().isEmpty)
        #expect(!keys.isHeld(0))
    }
}

extension KeyTrackerTests {
    @Test func releaseAllReleasesModifiersLast() {
        var keys = KeyTracker()
        keys.press(55, keysym: 0xFFE3)
        keys.press(0, keysym: 0x61)
        keys.press(56, keysym: 0xFFE1)
        let released = keys.releaseAll()
        #expect(released.first == 0x61)
        #expect(Set(released.dropFirst()) == [0xFFE3, 0xFFE1])
    }

    @Test func releaseNonModifiersKeepsModifiersHeld() {
        var keys = KeyTracker()
        keys.press(0, keysym: 0x61)
        keys.press(55, keysym: 0xFFE3)
        #expect(keys.releaseNonModifiers() == [0x61])
        #expect(keys.isHeld(55))
        #expect(!keys.isHeld(0))
    }
}

struct ScrollAccumulatorTests {
    private let up: UInt8 = 1 << 3, down: UInt8 = 1 << 4, left: UInt8 = 1 << 5, right: UInt8 = 1 << 6

    @Test func preciseDeltasAccumulateAcrossEvents() {
        var scroll = ScrollAccumulator()
        #expect(scroll.clicks(dx: 0, dy: 10, precise: true) == [])
        #expect(scroll.clicks(dx: 0, dy: 10, precise: true) == [up])
        #expect(scroll.clicks(dx: 0, dy: -40, precise: true) == [down, down])
    }

    @Test func horizontalPrecise() {
        var scroll = ScrollAccumulator()
        #expect(scroll.clicks(dx: 16, dy: 0, precise: true) == [left])
        #expect(scroll.clicks(dx: -32, dy: 0, precise: true) == [right, right])
    }

    @Test func lineDeltasClickPerLineWithAtLeastOne() {
        var scroll = ScrollAccumulator()
        #expect(scroll.clicks(dx: 0, dy: 1, precise: false) == [up])
        #expect(scroll.clicks(dx: 0, dy: -3, precise: false) == [down, down, down])
        #expect(scroll.clicks(dx: 0, dy: 0.2, precise: false) == [up])
        #expect(scroll.clicks(dx: 0, dy: 0, precise: false) == [])
    }
}
