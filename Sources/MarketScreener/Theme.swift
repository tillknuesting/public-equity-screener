import AppKit
import SwiftUI

/// Solarized (base16): base03…base3 for surfaces and text, eight accents for meaning.
/// Surface and text tokens flip between Solarized Dark and Light with the system appearance.
///
/// Type has three roles: `mono` for data (tickers, prices, numbers), `label` (condensed SF Pro,
/// sentence case) for names and words, `readout` (compressed SF Pro) for the few key numbers.
enum Theme {
    // Palette
    static let base03 = Color(hex: 0x002B36), base02 = Color(hex: 0x073642)
    static let base01 = Color(hex: 0x586E75), base00 = Color(hex: 0x657B83)
    static let base0 = Color(hex: 0x839496), base1 = Color(hex: 0x93A1A1)
    static let base2 = Color(hex: 0xEEE8D5), base3 = Color(hex: 0xFDF6E3)
    static let yellow = Color(hex: 0xB58900), orange = Color(hex: 0xCB4B16)
    static let red = Color(hex: 0xDC322F), magenta = Color(hex: 0xD33682)
    static let violet = Color(hex: 0x6C71C4), blue = Color(hex: 0x268BD2)
    static let cyan = Color(hex: 0x2AA198), green = Color(hex: 0x859900)

    // Surfaces
    static let canvas = adaptive(dark: 0x001C24, light: 0xE9E2CC)
    static let panel = adaptive(dark: 0x002B36, light: 0xFDF6E3)
    static let header = adaptive(dark: 0x073642, light: 0xEEE8D5)
    static let rowAlt = adaptive(dark: 0x022F3B, light: 0xF9F2DF)
    static let border = adaptive(dark: 0x0B4554, light: 0xD9D2BC)

    // Text
    static let text = adaptive(dark: 0x839496, light: 0x657B83)     // base0 / base00
    static let strong = adaptive(dark: 0x93A1A1, light: 0x586E75)   // base1 / base01
    static let bright = adaptive(dark: 0xEEE8D5, light: 0x073642)   // base2 / base02
    static let muted = adaptive(dark: 0x5F777F, light: 0x93A1A1)    // ≈ base01 / base1

    // Meaning
    static let up = green
    static let down = red
    static let accent = yellow
    static let selection = blue

    /// Data: tickers, prices, percentages.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Words: names, labels, explanations.
    static func label(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// The few headline numbers.
    static func readout(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.compressed).monospacedDigit()
    }

    static func signed(_ v: Double) -> Color { v < 0 ? down : up }

    static func score(_ s: Double) -> Color { s >= 70 ? green : s >= 50 ? yellow : muted }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// Animations used for responses to the user's actions; nil when Reduce Motion is on.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var ui: Animation? { reduce ? nil : .snappy(duration: 0.28) }
    static var smooth: Animation? { reduce ? nil : .smooth(duration: 0.4) }

    static func stagger(_ index: Int) -> Animation? {
        reduce ? nil : .snappy(duration: 0.32).delay(Double(index) * 0.045)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Small sentence-case label for column headers and stat captions.
struct Caption: View {
    let text: String
    var color: Color = Theme.muted

    init(_ text: String, color: Color = Theme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.label(11, .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A key number in the compressed readout face; rolls digits when it changes.
struct Readout: View {
    let text: String
    var size: CGFloat = 24
    var color: Color = Theme.bright

    var body: some View {
        Text(text)
            .font(Theme.readout(size))
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .fixedSize()
    }
}

/// A square pane with a title strip. A title written as "Title · detail" shows the detail muted.
struct Panel<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String?
    var marker: Color = Theme.accent
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, marker: Color = Theme.accent,
         @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        if let r = title.range(of: " · ") {
            self.title = String(title[..<r.lowerBound])
            self.subtitle = String(title[r.upperBound...]).replacingOccurrences(of: " · ", with: ", ")
        } else {
            self.title = title
            self.subtitle = nil
        }
        self.marker = marker
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(Theme.label(12.5, .semibold)).foregroundStyle(Theme.bright)
                if let subtitle {
                    Text(subtitle).font(Theme.label(12)).foregroundStyle(Theme.text)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                accessory()
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Theme.header)
            .overlay(alignment: .top) { marker.frame(height: 2) }
            Theme.border.frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String, marker: Color = Theme.accent, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, marker: marker, accessory: { EmptyView() }, content: content)
    }
}

struct TermButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = prominent ? Theme.accent : selected ? Theme.blue : Theme.header
        let ink: Color = prominent || selected ? Theme.base3 : Theme.strong
        configuration.label
            .font(Theme.label(compact ? 11 : 12, .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 2 : 4)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Rectangle())
            .overlay(Rectangle().stroke(prominent || selected ? .clear : Theme.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !Motion.reduce ? 0.96 : 1)
            .animation(Motion.reduce ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
            .animation(Motion.ui, value: selected)
    }
}

/// Terminal-style checkbox: `[x] Label`.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Motion.ui) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(configuration.isOn ? "[x]" : "[ ]")
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(configuration.isOn ? Theme.cyan : Theme.muted)
                configuration.label
                    .font(Theme.label(12, .medium))
                    .foregroundStyle(configuration.isOn ? Theme.bright : Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Tag: View {
    let text: String
    var color: Color = Theme.cyan

    var body: some View {
        Text(text)
            .font(Theme.mono(9.5, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.13), in: Rectangle())
            .overlay(Rectangle().stroke(color.opacity(0.45), lineWidth: 1))
            .fixedSize()
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = Theme.green

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.header)
                Rectangle().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .animation(Motion.smooth, value: fraction)
    }
}

/// A slowly pulsing dot for a gauge that is flashing stress; static under Reduce Motion.
struct PulseDot: View {
    var color: Color = Theme.magenta
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !Motion.reduce else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
