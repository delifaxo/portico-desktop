import Foundation

/// Fixed Steam destinations passed as a literal argument to the Windows client.
public enum SteamAction: Equatable, Sendable {
    case library, store, downloads
    case install(appID: String)
    case run(appID: String)

    public var uri: String {
        get throws {
            switch self {
            case .library: return "steam://open/games"
            case .store: return "steam://store"
            case .downloads: return "steam://open/downloads"
            case .install(let id): return "steam://install/\(try Self.validatedAppID(id))"
            case .run(let id): return "steam://rungameid/\(try Self.validatedAppID(id))"
            }
        }
    }

    public static func validatedAppID(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt32(value), number > 0 else {
            throw PorticoError.invalidInput(L10n.text("Steam App ID має бути додатним числом із посилання на гру в магазині Steam."))
        }
        return String(number)
    }
}
