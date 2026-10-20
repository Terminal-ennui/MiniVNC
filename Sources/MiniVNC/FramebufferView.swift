import AppKit
import VNCCore

/// Shows the remote framebuffer aspect-fit on black and forwards mouse and keyboard input.
@MainActor
final class FramebufferView: NSView {
    var session: RFBSession?

    private let imageLayer = CALayer()
    private var framebufferSize: CGSize = .zero
    private var buttons: UInt8 = 0
    private var lastPointer: (x: UInt16, y: UInt16) = (0, 0)
    private var keys = KeyTracker()
    private var scroll = ScrollAccumulator()
    private var cursorShape: CursorShape?
    private var cursorScale: CGFloat?
    private var remoteCursor = NSCursor.arrow
    private var trackingArea: NSTrackingArea?

    /// Per modifier key code: its device-dependent bit (IOLLEvent.h), so left/right state is exact, and the
    /// device-independent flag as a fallback for synthesized events that carry no device bits.
    private static let modifiers: [UInt16: (device: UInt, flag: NSEvent.ModifierFlags)] = [
        56: (0x02, .shift), 60: (0x04, .shift),
        59: (0x01, .control), 62: (0x2000, .control),
        58: (0x20, .option), 61: (0x40, .option),
        55: (0x08, .command), 54: (0x10, .command),
    ]
    private static let deviceModifierBits: UInt = 0x207F
    private static let capsLock: UInt16 = 57
    private static let leftOption: UInt16 = 58, rightOption: UInt16 = 61
    private static let hiddenCursor: NSCursor = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return NSCursor(image: NSImage(cgImage: context.makeImage()!, size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var transform: FitTransform { FitTransform(viewSize: bounds.size, contentSize: framebufferSize) }

    // MARK: - Display

    func display(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        let size = CGSize(width: image.width, height: image.height)
        if size != framebufferSize {
            framebufferSize = size
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = transform.contentRect
        CATransaction.commit()
        updateCursor()
    }

    func setRemoteCursor(_ shape: CursorShape) {
        cursorShape = shape
        cursorScale = nil
        updateCursor()
    }

    /// The remote cursor, scaled like the framebuffer so it lines up with what the server expects.
    private func updateCursor() {
        guard let shape = cursorShape else { return }
        let scale = framebufferSize.width > 0 ? max(transform.contentRect.width / framebufferSize.width, 0.25) : 1
        guard scale != cursorScale else { return }
        cursorScale = scale
        if let image = shape.image {
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let hotspot = NSPoint(x: shape.hotspot.x * scale, y: shape.hotspot.y * scale)
            remoteCursor = NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: hotspot)
        } else {
            remoteCursor = Self.hiddenCursor
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: remoteCursor)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setButton(1 << 0, down: true, event)
    }

    override func mouseUp(with event: NSEvent) { setButton(1 << 0, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { setButton(1 << 2, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { setButton(1 << 2, down: false, event) }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { setButton(1 << 1, down: true, event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { setButton(1 << 1, down: false, event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let clicks = scroll.clicks(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard let session, !clicks.isEmpty else { return }
        let point = framebufferPoint(event)
        for wheel in clicks {
            session.sendPointer(buttonMask: buttons | wheel, x: point.x, y: point.y)
            session.sendPointer(buttonMask: buttons, x: point.x, y: point.y)
        }
    }

    private func setButton(_ bit: UInt8, down: Bool, _ event: NSEvent) {
        if down { buttons |= bit } else { buttons &= ~bit }
        sendPointer(event)
    }

    private func sendPointer(_ event: NSEvent) {
        guard let session, framebufferSize != .zero else { return }
        lastPointer = framebufferPoint(event)
        session.sendPointer(buttonMask: buttons, x: lastPointer.x, y: lastPointer.y)
    }

    private func framebufferPoint(_ event: NSEvent) -> (x: UInt16, y: UInt16) {
        transform.framebufferPoint(for: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if let composed = rightOptionCharacter(event) {
            // Right ⌥ acts like AltGr: send the layout's ⌥-character (e.g. @ on German layouts) without Alt.
            let altR = Keysym.modifier(keyCode: Self.rightOption)!
            session.sendKey(altR, down: false)
            keys.press(event.keyCode, keysym: composed)
            session.sendKey(composed, down: true)
            session.sendKey(altR, down: true)
            return
        }
        guard let keysym = keysym(for: event) else { return }
        keys.press(event.keyCode, keysym: keysym)
        session.sendKey(keysym, down: true)
    }

    /// The character right ⌥ composes on the current layout, when only right ⌥ is held.
    private func rightOptionCharacter(_ event: NSEvent) -> UInt32? {
        let flags = event.modifierFlags
        guard keys.isHeld(Self.rightOption), !keys.isHeld(Self.leftOption),
              !flags.contains(.command), !flags.contains(.control),
              let characters = event.characters, characters != event.charactersIgnoringModifiers
        else { return nil }
        return Keysym.character(characters)
    }

    override func keyUp(with event: NSEvent) {
        guard let keysym = keys.release(event.keyCode) else { return }
        session?.sendKey(keysym, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let session, let keysym = Keysym.modifier(keyCode: event.keyCode) else { return }
        if event.keyCode == Self.capsLock {
            session.sendKey(keysym, down: true)
            session.sendKey(keysym, down: false)
            return
        }
        guard let modifier = Self.modifiers[event.keyCode] else { return }
        let flags = event.modifierFlags
        let isDown = flags.rawValue & Self.deviceModifierBits != 0
            ? flags.rawValue & modifier.device != 0
            : flags.contains(modifier.flag)
        if isDown, !keys.isHeld(event.keyCode) {
            if modifier.flag == .command {
                for held in keys.releaseNonModifiers() { session.sendKey(held, down: false) }
            }
            keys.press(event.keyCode, keysym: keysym)
            session.sendKey(keysym, down: true)
        } else if !isDown, let released = keys.release(event.keyCode) {
            session.sendKey(released, down: false)
        }
    }

    /// ⌘-combos arrive here instead of keyDown. They're sent as a tap because AppKit never delivers
    /// keyUp for keys pressed while ⌘ is held. A few shortcuts stay with the Mac (see Keysym.isLocalShortcut).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard event.type == .keyDown, flags.contains(.command), window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if Keysym.isLocalShortcut(event.charactersIgnoringModifiers ?? "", command: true, control: flags.contains(.control)) {
            return false
        }
        guard let session, let keysym = keysym(for: event) else { return false }
        session.sendKey(keysym, down: true)
        session.sendKey(keysym, down: false)
        return true
    }

    @objc func sendCtrlAltDelete(_ sender: Any?) {
        guard let session else { return }
        let keys: [UInt32] = [0xFFE3, 0xFFE9, 0xFFFF] // Control_L, Alt_L, Delete
        for keysym in keys { session.sendKey(keysym, down: true) }
        for keysym in keys.reversed() { session.sendKey(keysym, down: false) }
    }

    /// Releases every held key and button so nothing sticks on the remote when focus leaves.
    func releaseAllInput() {
        for keysym in keys.releaseAll() { session?.sendKey(keysym, down: false) }
        if buttons != 0 {
            buttons = 0
            session?.sendPointer(buttonMask: 0, x: lastPointer.x, y: lastPointer.y)
        }
    }

    private func keysym(for event: NSEvent) -> UInt32? {
        Keysym.special(keyCode: event.keyCode) ?? Keysym.character(event.charactersIgnoringModifiers ?? "")
    }
}
