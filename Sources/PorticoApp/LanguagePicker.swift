import SwiftUI
import PorticoCore

/// Shared by the main window and first-run setup so language is always discoverable.
struct LanguagePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach([AppLanguage.ukrainian, .english]) { language in
                Button { model.language = language } label: {
                    Text(language.label).font(.system(size: 11, weight: .semibold))
                        .frame(width: 42, height: 28)
                        .foregroundStyle(model.language == language ? Palette.onAccent : Palette.muted)
                        .background(model.language == language ? Palette.mint : .clear, in: Capsule())
                }.buttonStyle(.plain)
                    .accessibilityLabel(language == .english ? "English" : "Українська")
                    .accessibilityValue(model.language == language ? L10n.text("Вибрано") : "")
                    .accessibilityIdentifier("language-\(language.rawValue)")
            }
        }
        .padding(4).background(Palette.panel, in: Capsule())
        .help(L10n.text("Мова інтерфейсу"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Мова інтерфейсу"))
        .accessibilityIdentifier("interface-language-picker")
    }
}

enum GameFilter: String, CaseIterable, Identifiable {
    case all, favorites, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.text("Усі ігри")
        case .favorites: return L10n.text("Обране")
        case .recent: return L10n.text("Нещодавні")
        }
    }
}
