import AppKit
import SwiftUI

/// Semantic macOS surfaces and text, with Nutola's configurable action palette.
enum Theme {
    static let defaultActionColorHex = "#1A8917"

    static let cream = Color(red: 0.976, green: 0.969, blue: 0.957)          // #F9F7F4 brand mark
    static let raspberry = Color(red: 0.878, green: 0.224, blue: 0.420)     // #E0396B (preset)
    static let honey = Color(red: 0.949, green: 0.663, blue: 0.231)         // #F2A93B secondary
    static let blueberry = Color(red: 0.353, green: 0.416, blue: 0.812)     // #5A6ACF chat/links
    static let mint = Color(red: 0.247, green: 0.698, blue: 0.498)          // #3FB27F recording
    static let mediumGreen = Color(red: 0.102, green: 0.537, blue: 0.090)   // #1A8917 Medium accent

    static let cornerRadius: CGFloat = 16
    /// Main feed column width — widened to use more of the detail pane.
    static let contentMaxWidth: CGFloat = 960

    /// User-configurable accent for prominent actions (Record, Save, Stop, …).
    static var action: Color {
        Color(hex: AppSettings.actionColorHex) ?? mediumGreen
    }

    /// Opaque document and card surfaces keep long text readable.
    static func surface(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .windowBackgroundColor)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .controlBackgroundColor)
    }

    /// Expanded readers use an opaque surface beneath their controls.
    static func panel(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static func bubble(_ scheme: ColorScheme, isSelf: Bool) -> Color {
        if scheme == .dark {
            return isSelf
                ? Color(red: 0.22, green: 0.24, blue: 0.30)
                : Color(red: 0.19, green: 0.19, blue: 0.19)
        }
        return isSelf
            ? Color(red: 0.90, green: 0.95, blue: 0.89)   // #E6F2E5 green-tinted self bubble
            : Color(red: 0.95, green: 0.95, blue: 0.95)   // #F2F2F2 neutral
    }

    static func chip(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.18, green: 0.18, blue: 0.18)
            : Color(red: 0.95, green: 0.95, blue: 0.95)   // #F2F2F2 neutral
    }

    /// Primary text — titles, meeting names, body copy.
    static func heading(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .labelColor)
    }

    static func ink(_ scheme: ColorScheme) -> Color { heading(scheme) }

    /// Section labels ("Tomorrow", markdown h2, …) — readable on both surfaces.
    static func sectionTitle(_ scheme: ColorScheme, accent: Color) -> Color {
        accent.accentText(on: scheme)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static func tertiary(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    static func honey(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.95, green: 0.70, blue: 0.31)   // #F2B24F
            : honey
    }

    static func mint(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.45, green: 0.82, blue: 0.62)
            : mint
    }

    static func blueberry(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.58, green: 0.66, blue: 0.95)
            : blueberry
    }

    /// Prominent button fill — darkened/lightened so white labels meet contrast targets.
    static func prominentAction(_ color: Color, scheme: ColorScheme) -> Color {
        color.adjustedForProminentButton(on: scheme, surface: surface(scheme))
    }
}

enum ActionColorPreset: String, CaseIterable, Identifiable {
    case mediumGreen = "#1A8917"
    case raspberry = "#E0396B"
    case rose = "#F0708F"
    case coral = "#FF6B5A"
    case honey = "#F2A93B"
    case mint = "#3FB27F"
    case blueberry = "#5A6ACF"
    case violet = "#8B5CF6"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mediumGreen: "Medium Green"
        case .raspberry: "Raspberry"
        case .rose: "Rose"
        case .coral: "Coral"
        case .honey: "Honey"
        case .mint: "Mint"
        case .blueberry: "Blueberry"
        case .violet: "Violet"
        }
    }

    var color: Color { Color(hex: rawValue) ?? Theme.mediumGreen }
}

extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Accent text on a surface (section headers, inline highlights).
    func accentText(on scheme: ColorScheme) -> Color {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if scheme == .dark {
            b = min(1, b + 0.20)
            s = min(1, max(0.55, s))
        } else {
            b = max(0.30, b * 0.92)
            s = min(1, max(0.65, s))
        }
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }

    /// Button fill tuned for white label contrast and separation from the surface.
    func adjustedForProminentButton(on scheme: ColorScheme, surface: Color) -> Color {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        var candidate = hsbColor(h: h, s: s, b: b)
        while (candidate.contrastRatio(with: Color.white) ?? 0) < 4.5 && b > 0.28 {
            b -= 0.04
            s = min(1, s * 1.02)
            candidate = hsbColor(h: h, s: s, b: b)
        }

        if scheme == .dark {
            while (candidate.contrastRatio(with: surface) ?? 0) < 2.8 && b < 0.92 {
                b += 0.025
                candidate = hsbColor(h: h, s: s, b: b)
                if (candidate.contrastRatio(with: Color.white) ?? 0) < 4.5 {
                    b -= 0.025
                    candidate = hsbColor(h: h, s: s, b: b)
                    break
                }
            }
        }

        return candidate
    }

    func contrastRatio(with other: Color) -> Double? {
        guard let l1 = relativeLuminance(), let l2 = other.relativeLuminance() else { return nil }
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance() -> Double? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = channel(c.redComponent)
        let g = channel(c.greenComponent)
        let b = channel(c.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func hsbColor(h: CGFloat, s: CGFloat, b: CGFloat) -> Color {
        Color(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }
}

private struct NutolaActionColorKey: EnvironmentKey {
    static let defaultValue = Theme.action
}

extension EnvironmentValues {
    var nutolaActionColor: Color {
        get { self[NutolaActionColorKey.self] }
        set { self[NutolaActionColorKey.self] = newValue }
    }
}

struct NutolaAppearanceModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.appearanceMode) private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.actionColorHex) private var actionColorHex = Theme.defaultActionColorHex

    func body(content: Content) -> some View {
        let base = Color(hex: actionColorHex) ?? Theme.mediumGreen
        let action = Theme.prominentAction(base, scheme: scheme)
        content
            .preferredColorScheme(AppearanceMode(rawValue: appearanceMode)?.colorScheme)
            .environment(\.nutolaActionColor, action)
            .tint(action)
    }
}

extension View {
    func nutolaAppearance() -> some View {
        modifier(NutolaAppearanceModifier())
    }

    /// Constrain main content within the detail pane, left-aligned.
    func contentColumn(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: Theme.contentMaxWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Font {
    static func nutola(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }


}
