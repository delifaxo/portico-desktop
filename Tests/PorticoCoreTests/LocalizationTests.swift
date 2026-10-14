import Foundation
import XCTest
@testable import PorticoCore

final class LocalizationTests: XCTestCase {
    func testLanguagePreferencePersistsAndUnknownValuesFallBack() throws {
        let suite = "PorticoLocalizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.saved(in: defaults), .ukrainian)
        AppLanguage.english.save(in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: try XCTUnwrap(UserDefaults(suiteName: suite))), .english)
        AppLanguage.ukrainian.save(in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .ukrainian)
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .ukrainian)
    }

    func testLegacyPreferenceMigratesToUkrainian() throws {
        let suite = "PorticoLegacyLanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ru", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .ukrainian)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "uk")
        XCTAssertEqual(AppLanguage.saved(in: try XCTUnwrap(UserDefaults(suiteName: suite))), .ukrainian)
        AppLanguage.english.save(in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .english)
    }

    func testPickerOnlyOffersEnglishAndUkrainian() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["en", "uk"])
        XCTAssertEqual(AppLanguage.allCases.map(\.label), ["ENG", "UKR"])
        XCTAssertNil(AppLanguage(rawValue: "ru"))
        XCTAssertEqual(AppLanguage.ukrainian.locale.identifier, "uk_UA")
    }

    func testStoredMessageCanBeRenderedInEitherLanguage() {
        let message: LocalizedMessage = "Запущено: \("Jagged Alliance 2")"
        XCTAssertEqual(L10n.text(message, language: .english), "Running: Jagged Alliance 2")
        XCTAssertEqual(L10n.text(message, language: .ukrainian), "Запущено: Jagged Alliance 2")
        XCTAssertEqual(L10n.text("Налаштування гри", language: .ukrainian), "Налаштування гри")
        XCTAssertEqual(L10n.text("Створити середовище", language: .ukrainian), "Створити середовище")
    }

    func testInterpolationsPreserveUserTextAndProcessOutputVerbatim() {
        let path = "/Games/Гра {1}/100% 🕹️.exe"
        let output = "Wine output {0}\n%@"
        let message: LocalizedMessage = "Не вдалося прочитати бібліотеку \(path). Файл збережено без змін. \(output)"
        XCTAssertEqual(L10n.text(message, language: .english),
                       "Could not read the library at \(path). The file has been left unchanged. \(output)")
        XCTAssertEqual(L10n.text(message, language: .ukrainian),
                       "Не вдалося прочитати бібліотеку \(path). Файл збережено без змін. \(output)")
        XCTAssertEqual(L10n.text("Unknown message \(path)", language: .english), "Unknown message \(path)")
        XCTAssertEqual(L10n.text(LocalizedMessage(verbatim: "Бібліотека {0}"), language: .english), "Бібліотека {0}")
    }

    func testEveryTranslationPreservesItsInterpolationPlaceholders() throws {
        let pattern = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func tokens(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        XCTAssertGreaterThan(L10n.english.count, 200)
        XCTAssertEqual(Set(L10n.ukrainian.keys), Set(L10n.english.keys))
        for catalog in [L10n.english, L10n.ukrainian] {
            for (source, translation) in catalog {
                XCTAssertFalse(translation.isEmpty, source)
                XCTAssertEqual(tokens(source), tokens(translation), source)
            }
        }
    }
}
