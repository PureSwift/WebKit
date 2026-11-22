/// The keys and buttons held during an input event: `wpe_input_modifier`.
public struct WPEModifiers: OptionSet, Hashable, Sendable {

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = WPEModifiers(rawValue: 1 << 0)
    public static let shift = WPEModifiers(rawValue: 1 << 1)
    public static let alt = WPEModifiers(rawValue: 1 << 2)
    public static let meta = WPEModifiers(rawValue: 1 << 3)
    /// The primary button.
    public static let button1 = WPEModifiers(rawValue: 1 << 20)
    /// The secondary button.
    public static let button2 = WPEModifiers(rawValue: 1 << 21)
    /// The middle button.
    public static let button3 = WPEModifiers(rawValue: 1 << 22)
}

/// A button of a pointer, numbered as libwpe numbers them.
public enum WPEButton: UInt32, Hashable, Sendable {
    case primary = 1
    case secondary = 2
    case middle = 3

    /// The modifier that says the button is held.
    public var modifier: WPEModifiers {
        switch self {
        case .primary: .button1
        case .secondary: .button2
        case .middle: .button3
        }
    }
}

/// XKB key symbols, which key events carry.
public enum WPEKeysym {

    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let `return`: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let delete: UInt32 = 0xFFFF

    /// The symbol of the key that types a character, or nil for a control
    /// character or one in the private-use area, which have none.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x0A, 0x0D:
            return `return`
        case 0x20...0x7E, 0xA0...0xFF:
            // Latin-1's symbols are its code points.
            return scalar.value
        case 0x100...0x10FFFF where !(0xE000...0xF8FF).contains(scalar.value):
            return 0x0100_0000 | scalar.value
        default:
            return nil
        }
    }
}

// MARK: - libwpe's events

// Laid out as libwpe's structs, and passed to it by address.

/// `struct wpe_input_pointer_event`.
struct PointerEvent {
    /// `wpe_input_pointer_event_type`: 1 motion, 2 button.
    var type: UInt32
    var time: UInt32
    var x: Int32
    var y: Int32
    var button: UInt32
    var state: UInt32
    var modifiers: UInt32
}

/// `struct wpe_input_axis_2d_event`: a smooth scroll along both axes.
struct AxisEvent2D {
    /// `wpe_input_axis_event_type`: 2 motion-smooth, with the 2D flag.
    var type: UInt32 = 2 | 1 << 16
    var time: UInt32
    var x: Int32
    var y: Int32
    var axis: UInt32 = 0
    var value: Int32 = 0
    var modifiers: UInt32
    var xAxis: Double
    var yAxis: Double
}

/// `struct wpe_input_keyboard_event`.
struct KeyboardEvent {
    var time: UInt32
    /// An XKB key symbol.
    var keyCode: UInt32
    var hardwareKeyCode: UInt32
    var pressed: Bool
    var modifiers: UInt32
}
