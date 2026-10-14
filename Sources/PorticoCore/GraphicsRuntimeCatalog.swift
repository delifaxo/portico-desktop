import Foundation

/// Pinned archive metadata only. This does not establish a redistribution right,
/// an installed component set, or compatibility with the bundled Wine release.
public struct GraphicsProviderRelease: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    public let downloadBytes: Int64
    public let sourceURL: URL

    public init(id: String, name: String, version: String, downloadURL: URL, sha256: String,
                downloadBytes: Int64, sourceURL: URL) {
        self.id = id; self.name = name; self.version = version; self.downloadURL = downloadURL
        self.sha256 = sha256; self.downloadBytes = downloadBytes; self.sourceURL = sourceURL
    }
}

public enum GraphicsRuntimeCatalog {
    public static let appleGPTK3 = GraphicsProviderRelease(
        id: "gptk-3.0-3", name: "Game Porting Toolkit 3.0-3", version: "3.0-3",
        downloadURL: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
        sha256: "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e",
        downloadBytes: 239_200_808,
        sourceURL: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/tag/Game-Porting-Toolkit-3.0-3")!
    )

    public static func provider(id: String) -> GraphicsProviderRelease? {
        id == appleGPTK3.id ? appleGPTK3 : nil
    }
}
