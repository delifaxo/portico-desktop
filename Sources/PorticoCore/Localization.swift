import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case ukrainian = "uk"

    public var id: String { rawValue }
    public var label: String { self == .english ? "ENG" : "UKR" }
    public var locale: Locale { Locale(identifier: self == .english ? "en_US" : "uk_UA") }
    public static let preferenceKey = "Portico.interfaceLanguage"

    /// Migrate the legacy selection while preserving an explicit English choice.
    public static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        let stored = defaults.string(forKey: preferenceKey)
        if stored == "ru" {
            AppLanguage.ukrainian.save(in: defaults)
            return .ukrainian
        }
        return stored.flatMap(AppLanguage.init(rawValue:)) ?? .ukrainian
    }

    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

/// Keeps interpolation values separate from the translation key. Names, paths and
/// process output are inserted verbatim, even when they contain placeholder text.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]

    public init(verbatim value: String) {
        key = "{0}"
        arguments = [value]
    }

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    public static func text(_ message: LocalizedMessage, language: AppLanguage = .saved()) -> String {
        let catalog = language == .english ? english : ukrainian
        let template = catalog[message.key] ?? english[message.key] ?? message.key
        let result = NSMutableString(string: template)
        for match in placeholder.matches(in: template, range: NSRange(location: 0, length: result.length)).reversed() {
            let indexText = (template as NSString).substring(with: match.range(at: 1))
            if let index = Int(indexText), message.arguments.indices.contains(index) {
                result.replaceCharacters(in: match.range, with: message.arguments[index])
            }
        }
        return result as String
    }
}
