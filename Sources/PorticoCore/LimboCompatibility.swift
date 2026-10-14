import Foundation
import CryptoKit

/// Uses prerequisites supplied with the user's Steam copy. No redistributables
/// are downloaded or included in Portico, and overrides apply only to limbo.exe.
public enum LimboCompatibility {
    public static let registryKey = #"HKCU\Software\Wine\AppDefaults\limbo.exe\DllOverrides"#
    public static let libraries = ["d3dx9_43", "d3dcompiler_43"]
    static let microsoftHashes = [
        "d3dx9_43": "0b28546be22c71834501f7d7185ede5d79742457331c7ee09efc14490dd64f5f",
        "d3dcompiler_43": "2f23182ec6f4889397ac4bf03d62536136c5bdba825c7d2c4ef08c827f3a8a1c"
    ]

    public struct Status: Sendable {
        public let gameDirectory: URL?
        public let installer: URL?
        public let librariesReady: Bool
        public let overridesReady: Bool
        public var isReady: Bool { gameDirectory != nil && librariesReady && overridesReady }
    }

    public static func inspect(prefix: URL) throws -> Status {
        try inspect(prefix: prefix, hashes: microsoftHashes)
    }

    static func inspect(prefix: URL, hashes: [String: String]) throws -> Status {
        guard let game = try SteamSupport.installedGames(in: prefix).first(where: { $0.id == "48000" }) else {
            return Status(gameDirectory: nil, installer: nil, librariesReady: false, overridesReady: false)
        }
        let directory = game.installDirectory
        let setup = directory.appendingPathComponent("DirectX_Redist/DXSETUP.exe")
        let installer = regularFile(setup, within: directory, maximumSize: 10_000_000) ? setup : nil
        let ready = libraries.allSatisfy { name in
            // An app-local DLL takes precedence over the system copy. Never report
            // ready if an unknown app-local replacement shadows the verified one.
            let local = directory.appendingPathComponent(name + ".dll")
            if FileManager.default.fileExists(atPath: local.path) {
                return matches(local, root: directory, hash: hashes[name])
            }
            return matches(prefix.appendingPathComponent("drive_c/windows/syswow64/\(name).dll"),
                           root: prefix, hash: hashes[name])
        }
        let registry = prefix.appendingPathComponent("user.reg")
        let text = regularFile(registry, within: prefix, maximumSize: 8_000_000)
            ? (try? String(contentsOf: registry, encoding: .utf8)) ?? "" : ""
        return Status(gameDirectory: directory, installer: installer, librariesReady: ready,
                      overridesReady: hasNativeOverrides(in: text))
    }

    static func hasNativeOverrides(in registry: String) -> Bool {
        let header = #"[Software\\Wine\\AppDefaults\\limbo.exe\\DllOverrides]"#.lowercased()
        var inSection = false
        var native: Set<String> = []
        for raw in registry.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("[") { inSection = line.hasPrefix(header); continue }
            guard inSection else { continue }
            for name in libraries {
                if ["native", "native,builtin", "n", "n,b"].contains(where: { line == "\"\(name)\"=\"\($0)\"" }) {
                    native.insert(name)
                }
            }
        }
        return native.count == libraries.count
    }

    private static func matches(_ file: URL, root: URL, hash: String?) -> Bool {
        guard let hash, regularFile(file, within: root, maximumSize: 4_000_000),
              let data = try? Data(contentsOf: file) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash
    }

    private static func regularFile(_ file: URL, within root: URL, maximumSize: Int) -> Bool {
        let boundary = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().path.hasPrefix(boundary),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumSize else { return false }
        return true
    }
}
