import XCTest
@testable import PorticoCore

final class SteamCompatibilityTests: XCTestCase {
    private var root: URL!
    private var client: URL!
    private var helper: URL!
    private var launcher: URL!
    private var original: URL { helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_original.exe") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Steam compatibility \(UUID())").resolvingSymlinksInPath()
        client = root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        helper = client.deletingLastPathComponent().appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe")
        launcher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/Steam/steamwebhelper.exe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture(1).write(to: helper)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func fixture(_ marker: UInt8) throws -> Data {
        var data = try Data(contentsOf: launcher)
        data.append(Data(repeating: marker, count: 500_000))
        return data
    }

    func testPreservesOriginalAndRefreshesBackupAfterSteamUpdate() throws {
        let first = try Data(contentsOf: helper)
        try SteamCompatibility.prepare(client: client, prefix: root, launcher: launcher)
        XCTAssertEqual(try Data(contentsOf: original), first)
        try SteamCompatibility.prepare(client: client, prefix: root, launcher: launcher)
        XCTAssertEqual(try Data(contentsOf: original), first)
        let update = try fixture(2)
        try update.write(to: helper)
        try SteamCompatibility.prepare(client: client, prefix: root, launcher: launcher)
        XCTAssertEqual(try Data(contentsOf: original), update)
        XCTAssertEqual(try Data(contentsOf: helper), try Data(contentsOf: launcher))
    }

    func testChangedBackupFailsWithoutOverwritingEitherFile() throws {
        try SteamCompatibility.prepare(client: client, prefix: root, launcher: launcher)
        let changed = try fixture(3)
        try changed.write(to: original)
        XCTAssertThrowsError(try SteamCompatibility.prepare(client: client, prefix: root, launcher: launcher))
        XCTAssertEqual(try Data(contentsOf: original), changed)
    }

    func testSymlinkCannotRedirectWritesOutsidePrefix() throws {
        let outside = root.appendingPathComponent("outside.exe")
        let unchanged = try fixture(4)
        try unchanged.write(to: outside)
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: outside)
        XCTAssertThrowsError(try SteamCompatibility.prepare(client: client, prefix: root, launcher: launcher))
        XCTAssertEqual(try Data(contentsOf: outside), unchanged)
    }
}
