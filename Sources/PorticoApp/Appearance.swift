import SwiftUI
import AppKit
import PorticoCore

/// Semantic colors resolve against each window's appearance, including its sheets.
enum Palette {
    static let background = adaptive(light: 0xF3F2EC, dark: 0x222622)
    static let sidebar = adaptive(light: 0xF8F7F2, dark: 0x272C27)
    static let panel = adaptive(light: 0xFCFBF7, dark: 0x2C322C)
    static let elevated = adaptive(light: 0xE9EAE2, dark: 0x363D34)
    static let text = adaptive(light: 0x282D27, dark: 0xF0F0E8)
    static let muted = adaptive(light: 0x666F62, dark: 0xADB5A7)
    static let mint = adaptive(light: 0x627450, dark: 0xBAC9AD)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x23291F)
    static let amber = adaptive(light: 0x986017, dark: 0xE8BF87)
    static let separator = adaptive(light: 0xDDE0D5, dark: 0x3D453A)
    static let artwork = adaptive(light: 0xE5E8DD, dark: 0x30382D)
    static let artworkEnd = adaptive(light: 0xD5DDCB, dark: 0x3B4935)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct ThemePicker: View {
    @ObservedObject var model: AppModel
    var showsLabels = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(AppTheme.allCases) { theme in
                let title = theme == .light ? L10n.text("Світла") : L10n.text("Темна")
                Button { model.theme = theme } label: {
                    HStack(spacing: 6) {
                        Image(systemName: theme == .light ? "sun.max" : "moon")
                        if showsLabels { Text(title) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: showsLabels ? 78 : 24, minHeight: 28)
                    .padding(.horizontal, 5)
                    .foregroundStyle(model.theme == theme ? Palette.onAccent : Palette.muted)
                    .background(model.theme == theme ? Palette.mint : .clear, in: Capsule())
                }
                .buttonStyle(.plain).help(title).accessibilityLabel(title)
                .accessibilityValue(model.theme == theme ? L10n.text("Вибрано") : "")
                .accessibilityIdentifier("theme-\(theme.rawValue)")
            }
        }.padding(4).background(Palette.panel, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("Тема оформлення"))
    }
}

struct PorticoButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? Palette.onAccent : Palette.text)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(primary ? Palette.mint : Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
