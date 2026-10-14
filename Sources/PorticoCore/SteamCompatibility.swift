import Foundation
import CryptoKit

/// Opt-in workaround for CEF's black window on the bundled macOS Wine.
/// Valve's helper is preserved byte-for-byte beside the small argument launcher.
enum SteamCompatibility {
    private struct Receipt: Codable {
        let originalSHA256: String
        let launcherSHA256: String
    }

    static func prepare(client: URL, prefix: URL, launcher: URL) throws {
        guard !DistributionPolicy.isAppStore else {
            throw PorticoError.runtimeUnavailable("Steam compatibility mode is unavailable in this build.")
        }
        let directory = client.deletingLastPathComponent().appendingPathComponent("bin/cef/cef.win64")
        let helper = directory.appendingPathComponent("steamwebhelper.exe")
        let original = directory.appendingPathComponent("steamwebhelper_original.exe")
        let receiptURL = directory.appendingPathComponent("portico-webhelper.json")
        let boundary = prefix.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for file in [helper, original, receiptURL] {
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard canonical.count > boundary.count, canonical.starts(with: boundary),
                  file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else {
                throw PorticoError.storage("Steam compatibility files must stay inside the selected environment.")
            }
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw PorticoError.storage("Steam compatibility requires regular files.")
                }
            }
        }
        let launcherData = try Data(contentsOf: launcher)
        guard isPE64(launcherData), launcherData.count < 500_000 else {
            throw PorticoError.runtimeUnavailable("The bundled Steam compatibility launcher is missing or invalid.")
        }
        let current = try Data(contentsOf: helper, options: .mappedIfSafe)
        let launcherHash = hash(launcherData)
        let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        if current == launcherData || receipt?.launcherSHA256 == hash(current) {
            guard let receipt, let backup = try? Data(contentsOf: original, options: .mappedIfSafe),
                  hash(backup) == receipt.originalSHA256, isPE64(backup) else {
                throw PorticoError.runtimeUnavailable("Steam's original webhelper is missing or changed. Repair Steam before enabling compatibility mode.")
            }
            if current != launcherData {
                try JSONEncoder().encode(Receipt(originalSHA256: receipt.originalSHA256, launcherSHA256: launcherHash))
                    .write(to: receiptURL, options: .atomic)
                try launcherData.write(to: helper, options: .atomic)
            }
            return
        }
        // A normal Steam update may have restored a newer Valve helper. Preserve
        // that new executable before installing the launcher again. Never mistake
        // a small unknown wrapper for the original client.
        guard isPE64(current), current.count >= 500_000 else {
            throw PorticoError.runtimeUnavailable("Unrecognized Steam webhelper. Restore the official Steam client first.")
        }
        if FileManager.default.fileExists(atPath: original.path), receipt == nil {
            throw PorticoError.storage("An unmanaged Steam helper backup already exists; it was left unchanged.")
        }
        try current.write(to: original, options: .atomic)
        try JSONEncoder().encode(Receipt(originalSHA256: hash(current), launcherSHA256: launcherHash))
            .write(to: receiptURL, options: .atomic)
        try launcherData.write(to: helper, options: .atomic)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPE64(_ data: Data) -> Bool {
        guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a else { return false }
        let offset = (0..<4).reduce(0) { $0 | (Int(data[0x3c + $1]) << (8 * $1)) }
        guard offset >= 64, offset <= data.count - 26 else { return false }
        return Array(data[offset..<offset + 6]) == [0x50, 0x45, 0, 0, 0x64, 0x86]
            && data[offset + 24] == 0x0b && data[offset + 25] == 2
    }
}
