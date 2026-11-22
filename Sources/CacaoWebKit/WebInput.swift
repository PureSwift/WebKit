import Cacao
import Foundation
import WPEWebKit

/// Cacao's input to an external surface, as the engine's page takes it.
@MainActor
final class WebInput {

    /// The mouse buttons that are down.
    private var held: WPEModifiers = []

    /// The finger that is down, where it came down and where it last was.
    private var touch: (finger: UInt64, start: CGPoint, last: CGPoint, isScrolling: Bool)?

    /// How far a wheel's notch scrolls, in points.
    static let notch: Double = 40

    /// How far a finger moves, in points, before it scrolls instead of
    /// taps.
    static let slop: Double = 10

    func reset() {
        held = []
        touch = nil
    }

    func handle(_ input: ExternalInput, for content: WPEWebContent) {
        switch input {
        case let .pointer(phase, button, location):
            pointer(phase, Self.button(button), at: location, content)
        case let .hover(location):
            if let location {
                content.pointerMoved(x: location.x, y: location.y, modifiers: held)
            }
        case let .scroll(x, y, location):
            // A wheel turned away from the user moves toward the page's
            // start.
            content.scroll(x: location.x, y: location.y, dx: x * Self.notch, dy: -y * Self.notch)
            content.scroll(x: location.x, y: location.y, dx: 0, dy: 0)
        case let .touch(phase, finger, location):
            touched(phase, finger, at: location, content)
        case let .key(key):
            self.key(key, content)
        case let .text(text):
            content.type(text)
        case let .focus(focused):
            content.focus(focused)
        }
    }

    private func pointer(_ phase: ExternalInput.Phase, _ button: WPEButton, at location: CGPoint, _ content: WPEWebContent) {
        switch phase {
        case .began:
            content.pointerMoved(x: location.x, y: location.y, modifiers: held)
            held.insert(button.modifier)
            content.pointerButton(button, pressed: true, x: location.x, y: location.y, modifiers: held)
        case .moved:
            content.pointerMoved(x: location.x, y: location.y, modifiers: held)
        case .ended, .cancelled:
            held.remove(button.modifier)
            content.pointerButton(button, pressed: false, x: location.x, y: location.y, modifiers: held)
        }
    }

    /// One finger: a tap clicks, and a drag scrolls what is under it.
    private func touched(_ phase: ExternalInput.Phase, _ finger: UInt64, at location: CGPoint, _ content: WPEWebContent) {
        switch phase {
        case .began:
            guard touch == nil else { return }
            touch = (finger, location, location, false)
        case .moved:
            guard var current = touch, current.finger == finger else { return }
            if !current.isScrolling, abs(location.x - current.start.x) + abs(location.y - current.start.y) > Self.slop {
                current.isScrolling = true
            }
            if current.isScrolling {
                content.scroll(x: location.x, y: location.y, dx: current.last.x - location.x, dy: current.last.y - location.y)
            }
            current.last = location
            touch = current
        case .ended, .cancelled:
            guard let current = touch, current.finger == finger else { return }
            touch = nil
            if current.isScrolling {
                content.scroll(x: location.x, y: location.y, dx: 0, dy: 0)
            } else if phase == .ended {
                content.pointerMoved(x: location.x, y: location.y)
                content.pointerButton(.primary, pressed: true, x: location.x, y: location.y, modifiers: .button1)
                content.pointerButton(.primary, pressed: false, x: location.x, y: location.y)
            }
        }
    }

    /// Keys that type nothing go as keys. The rest arrive as text, which
    /// has the keyboard's layout and its shift applied, unless Control or
    /// Command makes a shortcut of them.
    private func key(_ key: ExternalInput.Key, _ content: WPEWebContent) {
        let modifiers = Self.modifiers(key.modifiers)
        if let keysym = Self.keysyms[key.usage] {
            return content.key(keysym: keysym, pressed: key.isDown, modifiers: modifiers)
        }
        guard !key.modifiers.isDisjoint(with: [.control, .command]),
              let scalar = Unicode.Scalar(key.keyCode), let keysym = WPEKeysym.keysym(for: scalar) else { return }
        content.key(keysym: keysym, pressed: key.isDown, modifiers: modifiers)
    }

    static func button(_ button: ExternalInput.Button) -> WPEButton {
        switch button {
        case .primary: .primary
        case .secondary: .secondary
        case .middle: .middle
        }
    }

    static func modifiers(_ modifiers: EventModifiers) -> WPEModifiers {
        var result: WPEModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.alt) }
        if modifiers.contains(.command) { result.insert(.meta) }
        return result
    }

    /// Key symbols by the key's usage in the USB HID keyboard page.
    static let keysyms: [UInt32: UInt32] = [
        0x28: WPEKeysym.return,
        0x29: WPEKeysym.escape,
        0x2A: WPEKeysym.backspace,
        0x2B: WPEKeysym.tab,
        0x4A: WPEKeysym.home,
        0x4B: WPEKeysym.pageUp,
        0x4C: WPEKeysym.delete,
        0x4D: WPEKeysym.end,
        0x4E: WPEKeysym.pageDown,
        0x4F: WPEKeysym.right,
        0x50: WPEKeysym.left,
        0x51: WPEKeysym.down,
        0x52: WPEKeysym.up,
        0x58: WPEKeysym.return,
    ]
}
