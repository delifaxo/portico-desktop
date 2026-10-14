import Foundation
import XCTest
@testable import PorticoCore

final class BundledRuntimeEnvironmentTests: XCTestCase {
    private var temporary: URL!
    private var bundle: URL!
    private var wine: URL!
    private var caches: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PorticoEnvironmentTests-" + UUID().uuidString, isDirectory: true)
        bundle = temporary.appendingPathComponent("A folder/Portico.app", isDirectory: true)
        wine = bundle.appendingPathComponent("Contents/Frameworks/WineRuntime/bin/wine")
        caches = temporary.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture, never executed".utf8).write(to: wine)
        try writeManifest(["id": "wine-private-11.0_1", "architecture": "x86_64"])
        try writeGStreamerVersion("1.28.1")
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    private var inherited: [String: String] {
        ["GST_PLUGIN_PATH": "/external/plugins", "GST_PLUGIN_PATH_1_0": "/newer/plugins",
         "GST_PLUGIN_SYSTEM_PATH": "/system/plugins", "GST_PLUGIN_SYSTEM_PATH_1_0": "/other/system",
         "GST_PLUGIN_SCANNER": "/external/scanner", "GST_PLUGIN_SCANNER_1_0": "/other/scanner",
         "GIO_EXTRA_MODULES": "/external/gio", "GIO_MODULE_DIR": "/system/gio",
         "GST_REGISTRY": "/external/registry.bin", "GST_REGISTRY_1_0": "/other/registry.bin",
         "LANG": "uk_UA.UTF-8", "PATH": "/existing/path", "WINEPREFIX": "/my/bottle", "WINEDEBUG": "-all"]
    }

    private func apply(executable: URL? = nil, cacheRoot: URL? = nil) -> [String: String] {
        BundledRuntimeEnvironment.applying(to: inherited, executable: executable ?? wine,
                                           bundleURL: bundle, cacheRoot: cacheRoot ?? caches)
    }

    private func writeManifest(_ manifest: [String: String]) throws {
        let url = bundle.appendingPathComponent("Contents/Resources/RuntimeManifest.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    private func writeGStreamerVersion(_ version: String) throws {
        let url = bundle.appendingPathComponent("Contents/Frameworks/GStreamer.framework/Versions/Current/Resources/Info.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0).write(to: url)
    }

    func testBundledEngineUsesPrivatePluginsAndPreservesUnrelatedEnvironment() throws {
        let environment = apply()
        let gstreamer = bundle.appendingPathComponent("Contents/Frameworks/GStreamer.framework/Versions/Current")
        for key in ["GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SYSTEM_PATH_1_0"] {
            XCTAssertEqual(environment[key], gstreamer.appendingPathComponent("lib/gstreamer-1.0").path)
        }
        for key in ["GST_PLUGIN_SCANNER", "GST_PLUGIN_SCANNER_1_0"] {
            XCTAssertEqual(environment[key], gstreamer.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path)
        }
        XCTAssertEqual(environment["GIO_EXTRA_MODULES"], gstreamer.appendingPathComponent("lib/gio/modules").path)
        XCTAssertEqual(environment["GIO_MODULE_DIR"], gstreamer.appendingPathComponent("lib/gio/modules").path)
        for key in ["GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0"] { XCTAssertNil(environment[key]) }
        for key in ["LANG", "PATH", "WINEPREFIX", "WINEDEBUG"] { XCTAssertEqual(environment[key], inherited[key]) }
        let registry = URL(fileURLWithPath: try XCTUnwrap(environment["GST_REGISTRY_1_0"]))
        XCTAssertEqual(environment["GST_REGISTRY"], registry.path)
        XCTAssertEqual(registry.lastPathComponent, "registry-gstreamer-1.28.1-x86_64.bin")
        XCTAssertEqual(registry.deletingLastPathComponent().lastPathComponent, "wine-private-11.0_1")
        XCTAssertTrue(registry.path.hasPrefix(caches.path + "/"))
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: registry.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path), "Configuration must not overwrite an existing registry")
    }

    func testExternalAndLookalikeEnginesAreUnchangedWithoutCreatingCaches() {
        for executable in [temporary.appendingPathComponent("External/bin/wine"),
                           bundle.appendingPathComponent("Contents/Frameworks/WineRuntime-other/bin/wine"),
                           bundle.appendingPathComponent("Contents/Frameworks/WineRuntime/bin/wineserver"),
                           URL(string: "https://example.invalid/wine")!] {
            XCTAssertEqual(apply(executable: executable), inherited)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path))
    }

    func testPathsFollowRelocatedBundleInsteadOfOriginalInstallLocation() throws {
        let original = bundle!
        let relocated = temporary.appendingPathComponent("Moved Portico.app", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: relocated)
        bundle = relocated
        wine = relocated.appendingPathComponent("Contents/Frameworks/WineRuntime/bin/wine")
        let environment = apply()
        for key in ["GST_PLUGIN_SYSTEM_PATH_1_0", "GST_PLUGIN_SCANNER_1_0", "GIO_EXTRA_MODULES", "GIO_MODULE_DIR"] {
            XCTAssertTrue(try XCTUnwrap(environment[key]).hasPrefix(relocated.path + "/"))
            XCTAssertFalse(try XCTUnwrap(environment[key]).contains(original.path))
        }
    }

    func testCanonicalAliasIsRecognizedButBundledSymlinkCannotEscape() throws {
        let alias = temporary.appendingPathComponent("wine-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: wine)
        XCTAssertNotEqual(apply(executable: alias), inherited)

        let external = temporary.appendingPathComponent("external-wine")
        try Data("external fixture".utf8).write(to: external)
        try FileManager.default.removeItem(at: wine)
        try FileManager.default.createSymbolicLink(at: wine, withDestinationURL: external)
        XCTAssertEqual(apply(), inherited)
        XCTAssertEqual(apply(executable: external), inherited)
    }

    func testRegistrySeparatesFrameworkVersionsAndRuntimeArchitectures() throws {
        let initial = try XCTUnwrap(apply()["GST_REGISTRY_1_0"])
        try writeGStreamerVersion("1.30.0")
        try writeManifest(["id": "wine-private-next", "architecture": "arm64"])
        let updated = try XCTUnwrap(apply()["GST_REGISTRY_1_0"])
        XCTAssertNotEqual(initial, updated)
        XCTAssertEqual(URL(fileURLWithPath: updated).lastPathComponent, "registry-gstreamer-1.30.0-arm64.bin")
        XCTAssertEqual(URL(fileURLWithPath: updated).deletingLastPathComponent().lastPathComponent, "wine-private-next")
    }

    func testBlockedCacheRootUsesPrivateWritableFallbackAndUnsafeMetadataCannotEscape() throws {
        let blockedRoot = temporary.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedRoot)
        try writeManifest(["id": "../../outside", "architecture": "../escape"])
        try writeGStreamerVersion("../../../outside")
        let environment = apply(cacheRoot: blockedRoot)
        let registry = URL(fileURLWithPath: try XCTUnwrap(environment["GST_REGISTRY_1_0"]))
        let fallback = registry.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fallback) }
        XCTAssertTrue(fallback.lastPathComponent.hasPrefix("PorticoRuntimeCache-"))
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: fallback.path))
        XCTAssertEqual(registry.lastPathComponent, "registry-gstreamer-unknown-x86_64.bin")
        XCTAssertNotEqual(environment["GST_REGISTRY_1_0"], inherited["GST_REGISTRY_1_0"])
        XCTAssertEqual(try Data(contentsOf: blockedRoot), Data("file".utf8))
    }
}
