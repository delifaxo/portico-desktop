import Foundation

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark

    public var id: String { rawValue }
    public static let preferenceKey = "Portico.interfaceTheme"

    public static func saved(in defaults: UserDefaults = .standard) -> AppTheme {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .dark
    }

    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
