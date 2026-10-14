import XCTest
import CryptoKit
@testable import PorticoCore

final class LimboCompatibilityTests: XCTestCase {
    private var root: URL!
    private var game: URL!
    private let payload = Data("test Microsoft prerequisite".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Portico Limbo \(UUID())")
            .resolvingSymlinksInPath()
        let steam = root.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        game = steam.appendingPathComponent("steamapps/common/Limbo")
        try file(steam.appendingPathComponent("steam.exe"), Data("fixture".utf8))
        try file(steam.appendingPathComponent("steamapps/appmanifest_48000.acf"), Data(
            #"""
            "AppState" { "appid" "48000" "name" "LIMBO" "installdir" "Limbo" "StateFlags" "4" }
            """#.utf8))
        try file(game.appendingPathComponent("limbo.exe"), Data("fixture".utf8))
        for name in LimboCompatibility.libraries {
            try file(root.appendingPathComponent("drive_c/windows/syswow64/\(name).dll"), payload)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func file(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private var hashes: [String: String] {
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return Dictionary(uniqueKeysWithValues: LimboCompatibility.libraries.map { ($0, hash) })
    }
    private var overrides: String {
        #"""
        [Software\\Wine\\AppDefaults\\LIMBO.exe\\DllOverrides] 100
        "d3dx9_43"="native,builtin"
        "d3dcompiler_43"="native,builtin"
        """#
    }

    func testReadyRequiresOriginalLibrariesAndBothGameOverrides() throws {
        var status = try LimboCompatibility.inspect(prefix: root, hashes: hashes)
        XCTAssertTrue(status.librariesReady)
        XCTAssertFalse(status.isReady)
        try file(root.appendingPathComponent("user.reg"), Data(overrides.utf8))
        status = try LimboCompatibility.inspect(prefix: root, hashes: hashes)
        XCTAssertTrue(status.isReady)
        // Fixture bytes must never pass the actual Microsoft fingerprints.
        XCTAssertFalse(try LimboCompatibility.inspect(prefix: root).librariesReady)
    }

    func testAnotherGamesOverridesDoNotQualify() {
        XCTAssertFalse(LimboCompatibility.hasNativeOverrides(in: overrides.replacingOccurrences(of: "LIMBO.exe", with: "other.exe")))
        XCTAssertFalse(LimboCompatibility.hasNativeOverrides(in: overrides.replacingOccurrences(of: #""d3dx9_43"="native,builtin""#, with: #""d3dx9_43"="builtin,native""#)))
    }

    func testUnknownAppLocalDLLShadowsVerifiedSystemCopy() throws {
        let local = game.appendingPathComponent("d3dx9_43.dll")
        try file(local, Data("custom wrapper".utf8))
        XCTAssertFalse(try LimboCompatibility.inspect(prefix: root, hashes: hashes).librariesReady)
        XCTAssertEqual(try Data(contentsOf: local), Data("custom wrapper".utf8))
        try payload.write(to: local)
        XCTAssertTrue(try LimboCompatibility.inspect(prefix: root, hashes: hashes).librariesReady)
    }

    func testInstallerCannotEscapeGameDirectory() throws {
        let outside = root.appendingPathComponent("outside.exe")
        try file(outside, Data("fixture".utf8))
        let link = game.appendingPathComponent("DirectX_Redist/DXSETUP.exe")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(try LimboCompatibility.inspect(prefix: root, hashes: hashes).installer)
    }

    func testIncompleteSteamInstallationIsNotReadyAndInspectionKeepsSettings() throws {
        let settings = game.appendingPathComponent("settings.txt")
        let contents = Data("use30hz = false\r\nuse8bitrender = true\r\n".utf8)
        try file(settings, contents)
        let manifest = game.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("appmanifest_48000.acf")
        let data = try String(contentsOf: manifest).replacingOccurrences(of: #""StateFlags" "4""#, with: #""StateFlags" "6""#)
        try data.write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertNil(try LimboCompatibility.inspect(prefix: root, hashes: hashes).gameDirectory)
        XCTAssertEqual(try Data(contentsOf: settings), contents)
    }

    func testSteamRedistributablesAreNotOfferedAsAGame() throws {
        let apps = game.deletingLastPathComponent().deletingLastPathComponent()
        try file(apps.appendingPathComponent("appmanifest_228980.acf"), Data(
            #"""
            "AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "installdir" "Steamworks Shared" "StateFlags" "4" }
            """#.utf8))
        try file(apps.appendingPathComponent("common/Steamworks Shared/fixture"), Data("fixture".utf8))
        XCTAssertEqual(try SteamSupport.installedGames(in: root).map(\.id), ["48000"])
    }
}
