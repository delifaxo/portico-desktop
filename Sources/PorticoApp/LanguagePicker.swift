import SwiftUI
import PorticoCore

/// Shared by the main window and first-run setup so language is always discoverable.
struct LanguagePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker(L10n.text("Мова інтерфейсу"), selection: $model.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.label).tag(language)
                    .accessibilityLabel(language == .english ? "English" : "Українська")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 116)
        .help(L10n.text("Мова інтерфейсу"))
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
