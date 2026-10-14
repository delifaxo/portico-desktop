import Foundation

public enum BottleStatus: String, Codable, Sendable {
    case creating, ready, failed
}

public struct Bottle: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var status: BottleStatus
    public var enginePath: String
    /// Absent in older libraries; nil preserves the runtime's default graphics behavior.
    public var graphics: BottleGraphics?
    /// Opt-in Steam window workaround; other programs retain their launch settings.
    public var steamDesktop: Bool?
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), status: BottleStatus = .creating, enginePath: String, graphics: BottleGraphics? = nil, steamDesktop: Bool? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.status = status; self.enginePath = enginePath
        self.graphics = graphics
        self.steamDesktop = steamDesktop
    }
}

public struct Game: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var bottleID: UUID
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var isFavorite: Bool
    /// Steam games launch through the Windows client, which handles DRM and prerequisites.
    /// Optional so libraries saved before Steam support still decode without migration.
    public var steamAppID: String?
    /// nil retains the launch behavior of libraries saved before the route picker.
    public var launchMethod: GameLaunchMethod?
    /// Optional route to a user-selected, existing CrossOver Menu Helper.
    public var crossOverLauncher: CrossOverGame?
    /// nil preserves the graphics behavior of older libraries.
    public var graphicsProfile: GameGraphicsProfile?
    /// Steam stores steam.exe as the launcher; graphics overrides need the game's executable.
    public var graphicsExecutablePath: String?
    public init(id: UUID = UUID(), name: String, bottleID: UUID, executablePath: String, arguments: [String] = [], workingDirectory: String? = nil, addedAt: Date = Date(), lastPlayedAt: Date? = nil, isFavorite: Bool = false, steamAppID: String? = nil, launchMethod: GameLaunchMethod? = nil, crossOverLauncher: CrossOverGame? = nil) {
        self.id = id; self.name = name; self.bottleID = bottleID
        self.executablePath = executablePath; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt; self.isFavorite = isFavorite
        self.steamAppID = steamAppID
        self.launchMethod = launchMethod
        self.crossOverLauncher = crossOverLauncher
    }

    public var effectiveLaunchMethod: GameLaunchMethod { launchMethod ?? (steamAppID == nil ? .executable : .steam) }
    public var effectiveGraphicsProfile: GameGraphicsProfile { graphicsProfile ?? .automatic }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var enginePath: String
    public var verboseLogging: Bool
    public var showFPS: Bool
    public init(enginePath: String = "", verboseLogging: Bool = false, showFPS: Bool = false) {
        self.enginePath = enginePath; self.verboseLogging = verboseLogging; self.showFPS = showFPS
    }
    private enum CodingKeys: String, CodingKey { case enginePath, verboseLogging, showFPS }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enginePath = try values.decode(String.self, forKey: .enginePath)
        verboseLogging = try values.decode(Bool.self, forKey: .verboseLogging)
        showFPS = try values.decodeIfPresent(Bool.self, forKey: .showFPS) ?? false
    }
}

public struct Library: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var bottles: [Bottle]
    public var games: [Game]
    public var settings: AppSettings
    /// Optional so libraries created before CrossOver launcher support still decode.
    public var crossOverGames: [CrossOverGame]?
    public init(schemaVersion: Int = 1, bottles: [Bottle] = [], games: [Game] = [], settings: AppSettings = AppSettings(), crossOverGames: [CrossOverGame]? = nil) {
        self.schemaVersion = schemaVersion; self.bottles = bottles
        self.games = games; self.settings = settings
        self.crossOverGames = crossOverGames
    }
}

public struct WineRuntime: Identifiable, Equatable, Sendable {
    public var id: String { executableURL.path }
    public let name: String
    public let executableURL: URL
    public init(name: String, executableURL: URL) {
        self.name = name; self.executableURL = executableURL
    }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public init(exitCode: Int32, output: String) { self.exitCode = exitCode; self.output = output }
}

public enum PorticoError: LocalizedError {
    case invalidInput(String), runtimeUnavailable(String), processFailed(Int32, String), storage(String), busy
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .runtimeUnavailable(let message), .storage(let message): return message
        case .processFailed(let code, let output): return L10n.text("Wine завершився з кодом \(code).\n\(output.suffix(1800))")
        case .busy: return L10n.text("У цьому середовищі вже виконується операція.")
        }
    }
}
