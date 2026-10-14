import Foundation
import XCTest
@testable import PorticoCore

final class LocalGraphicsRuntimeTests: XCTestCase {
    private var root: URL!
    private var runtime: URL!

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent("work/byob-tests/" + UUID().uuidString).resolvingSymlinksInPath()
        runtime = root.appendingPathComponent("External Kit.app/Contents/Resources/wine")
        for (path, executable) in LocalGraphicsRuntime.requiredFiles {
            let file = runtime.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((executable ? "#!/bin/sh\nexit 0\n" : "fixture " + path).utf8).write(to: file)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testAcceptsCompleteAppDirectoryAndExecutableWithoutCopying() throws {
        for selection in [runtime!, root.appendingPathComponent("External Kit.app"), runtime.appendingPathComponent("bin/wine64")] {
            XCTAssertEqual(try LocalGraphicsRuntime.inspect(selection: selection).path, runtime.path)
        }
        let registration = try LocalGraphicsRuntime.snapshot(runtime: runtime, version: "wine-7.7")
        try LocalGraphicsRuntime.save(registration, rootURL: root.appendingPathComponent("Graphics"))
        let selected = LocalGraphicsRuntime.selectedProviderID(rootURL: root.appendingPathComponent("Graphics"))
        XCTAssertEqual(selected, registration.providerID)
        let reference = try GraphicsRuntimeLocation.reference(providerID: registration.providerID)
        XCTAssertEqual(try GraphicsRuntimeLocation.resolve(reference: reference, rootURL: root.appendingPathComponent("Graphics")), runtime.appendingPathComponent("bin/wine64"))
        XCTAssertNoThrow(try BottleGraphics(backend: .d3dMetal, providerID: registration.providerID).validate())
        XCTAssertEqual(try LocalGraphicsRuntime.snapshot(runtime: runtime, version: registration.wineVersion, id: registration.providerID), registration)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Graphics").path), ["LocalRuntimes"])
    }

    func testRejectsLibraryOnlyIncompleteAndRemoteSelections() throws {
        XCTAssertThrowsError(try LocalGraphicsRuntime.inspect(selection: runtime.appendingPathComponent("lib/external/D3DMetal.framework")))
        XCTAssertThrowsError(try LocalGraphicsRuntime.inspect(selection: URL(string: "https://example.com/kit")!))
        XCTAssertThrowsError(try LocalGraphicsRuntime.inspect(selection: URL(fileURLWithPath: "/Volumes/GPTK/wine")))
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("bin/wineserver"))
        XCTAssertThrowsError(try LocalGraphicsRuntime.inspect(selection: runtime))
    }

    func testRejectsEscapingLibraryAndMismatchedWineServer() throws {
        for path in ["bin/wineserver", "lib/external/D3DMetal.framework/D3DMetal"] {
            let file = runtime.appendingPathComponent(path)
            let external = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: file, to: external)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
            XCTAssertThrowsError(try LocalGraphicsRuntime.inspect(selection: runtime))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: external, to: file)
        }
    }

    func testRejectsUnregisteredMalformedAndTraversalIDs() throws {
        for id in ["local-", "local-../escape", "local-/tmp/wine", "local-" + UUID().uuidString.uppercased()] {
            XCTAssertFalse(LocalGraphicsRuntime.isLocalProvider(id))
            XCTAssertThrowsError(try GraphicsRuntimeLocation.reference(providerID: id))
        }
        XCTAssertThrowsError(try LocalGraphicsRuntime.resolve(providerID: "local-" + UUID().uuidString.lowercased(), rootURL: root))
    }

    func testChangedOrMovedRuntimeNeverFallsBackToAnotherEngine() throws {
        let registration = try LocalGraphicsRuntime.snapshot(runtime: runtime, version: "wine-7.7")
        try LocalGraphicsRuntime.save(registration, rootURL: root)
        let dll = runtime.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")
        try Data("changed".utf8).write(to: dll)
        XCTAssertThrowsError(try LocalGraphicsRuntime.resolve(providerID: registration.providerID, rootURL: root))
        try FileManager.default.moveItem(at: runtime, to: root.appendingPathComponent("moved"))
        XCTAssertThrowsError(try LocalGraphicsRuntime.resolve(providerID: registration.providerID, rootURL: root))
        XCTAssertEqual(LocalGraphicsRuntime.selectedProviderID(rootURL: root), registration.providerID)
    }

    func testNewSelectionPreservesPreviousRegistration() throws {
        let first = try LocalGraphicsRuntime.snapshot(runtime: runtime, version: "wine-7.7")
        let second = try LocalGraphicsRuntime.snapshot(runtime: runtime, version: "wine-7.7")
        try LocalGraphicsRuntime.save(first, rootURL: root)
        try LocalGraphicsRuntime.save(second, rootURL: root)
        XCTAssertEqual(LocalGraphicsRuntime.selectedProviderID(rootURL: root), second.providerID)
        XCTAssertEqual(try LocalGraphicsRuntime.resolve(providerID: first.providerID, rootURL: root), runtime.appendingPathComponent("bin/wine64"))
        XCTAssertThrowsError(try LocalGraphicsRuntime.save(first, rootURL: root))
    }

    func testWineForgeRegistrationPinsItsOwnBridgesAndRejectsChanges() throws {
        let forge = root.appendingPathComponent("WineForgeCore")
        for (path, executable) in LocalGraphicsRuntime.wineForgeFiles {
            let file = forge.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("fixture " + path).utf8).write(to: file)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        XCTAssertEqual(try LocalGraphicsRuntime.inspect(selection: forge.appendingPathComponent("bin/wine")).path, forge.path)
        let saved = try LocalGraphicsRuntime.snapshot(runtime: forge, version: "wine-11.17 (WineForge 0.6.0.4)")
        XCTAssertEqual(saved.schemaVersion, 2)
        XCTAssertEqual(saved.layout, "wineforge")
        try LocalGraphicsRuntime.save(saved, rootURL: root)
        XCTAssertEqual(try LocalGraphicsRuntime.resolve(providerID: saved.providerID, rootURL: root), forge.appendingPathComponent("bin/wine"))
        try Data("changed bridge".utf8).write(to: forge.appendingPathComponent("lib/d3dmetal/wine/x86_64-unix/d3d12.so"))
        XCTAssertThrowsError(try LocalGraphicsRuntime.resolve(providerID: saved.providerID, rootURL: root))
    }

    func testWineForgeEnvironmentUsesOnlyItsRegisteredLocalLayer() throws {
        let forge = root.appendingPathComponent("WineForgeCore")
        let environment = GraphicsRuntimeLocation.applyingEnvironment(to: [
            "D3DM_DEVICE_ID": "123", "VKD3D_FEATURE_LEVEL": "12_2", "WINEDLLPATH": "/wrong",
            "GRAPHICS_BACKEND": "dxmt", "D3DMETAL_RUNTIME_DIR": "/wrong", "WFDXCOMPAT_RUNTIME_DIR": "/wrong"
        ], executable: forge.appendingPathComponent("bin/wine"), providerID: "local-" + UUID().uuidString.lowercased())
        XCTAssertEqual(environment["GRAPHICS_BACKEND"], "d3dmetal")
        XCTAssertEqual(environment["D3DMETAL_RUNTIME_DIR"], forge.appendingPathComponent("lib/d3dmetal").path)
        XCTAssertEqual(environment["WFDXCOMPAT_RUNTIME_DIR"], "/dev/null")
        for key in ["D3DM_DEVICE_ID", "VKD3D_FEATURE_LEVEL", "WINEDLLPATH"] {
            XCTAssertNil(environment[key])
        }
    }

    func testInvalidAppleSignatureDoesNotExecuteOrRegisterSelection() async throws {
        let marker = root.appendingPathComponent("executed")
        let wine = runtime.appendingPathComponent("bin/wine64")
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".utf8).write(to: wine)
        do {
            _ = try await LocalGraphicsRuntime.connect(selection: runtime, rootURL: root)
            XCTFail("Unsigned Apple components must be rejected before Wine runs")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(LocalGraphicsRuntime.selectedProviderID(rootURL: root))
    }

    func testLocalInstalledRuntimeCanInitializeAndDiagnoseDX12() async throws {
        guard let path = ProcessInfo.processInfo.environment["PORTICO_DX12_INTEGRATION_ROOT"] else {
            throw XCTSkip("Set PORTICO_DX12_INTEGRATION_ROOT for the real local-runtime test")
        }
        let managedRoot = URL(fileURLWithPath: path)
        let wine = try GraphicsRuntimeLocation.resolve(reference: GraphicsRuntimeLocation.reference(providerID: GraphicsRuntimeCatalog.appleGPTK3.id), rootURL: managedRoot)
        let registration = try await LocalGraphicsRuntime.connect(selection: wine, rootURL: root)
        let reference = try GraphicsRuntimeLocation.reference(providerID: registration.providerID)
        let engine = WineEngine(graphicsRoot: root)
        var bottle = Bottle(name: "BYOB integration", enginePath: reference,
                            graphics: BottleGraphics(backend: .d3dMetal, providerID: registration.providerID))
        let prefix = root.appendingPathComponent("prefix")
        let probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/Diagnostics/d3d12-probe.exe")
        do {
            _ = try await engine.initialize(bottle: bottle, prefix: prefix, logURL: root.appendingPathComponent("boot.log"), verbose: false)
            bottle.status = .ready
            let report = try await engine.diagnoseGraphics(bottle: bottle, prefix: prefix, probeURL: probe,
                logURL: root.appendingPathComponent("probe.log"), verbose: false)
            XCTAssertTrue(report.supportsDX12FeatureLevel12)
            try await engine.stop(bottle: bottle, prefix: prefix)
        } catch {
            try? await engine.stop(bottle: bottle, prefix: prefix)
            throw error
        }
    }
}
