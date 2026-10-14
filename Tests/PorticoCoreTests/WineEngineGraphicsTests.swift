import XCTest
@testable import PorticoCore

final class WineEngineGraphicsTests: XCTestCase {
    private var root: URL!
    private var prefix: URL!
    private var probe: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Portico Graphics Tests \(UUID().uuidString)")
        prefix = root.appendingPathComponent("prefix")
        probe = root.appendingPathComponent("capability probe.exe")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        try Data().write(to: probe)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testGraphicsSelectionMustMatchStableEngineReferenceBeforeExecution() async throws {
        let engine = WineEngine(graphicsRoot: root)
        let graphics = BottleGraphics(backend: .d3dMetal, providerID: GraphicsRuntimeCatalog.appleGPTK3.id)
        let mismatched = [
            Bottle(name: "Invalid overlay", status: .ready, enginePath: "portico-bundled://wine-stable-11.0_1", graphics: graphics),
            Bottle(name: "Missing graphics", status: .ready, enginePath: "portico-graphics://gptk-3.0-3"),
            Bottle(name: "Unknown graphics", status: .ready, enginePath: "portico-graphics://unknown", graphics: graphics)
        ]
        for bottle in mismatched {
            do {
                _ = try await engine.diagnoseGraphics(bottle: bottle, prefix: prefix, probeURL: probe,
                    logURL: root.appendingPathComponent("mismatch.log"), verbose: false)
                XCTFail("A mismatched graphics runtime must not execute")
            } catch { XCTAssertTrue(error is PorticoError) }
        }
    }

    func testDiagnosticStopsItsCompletedProbeSessionAndParsesCapabilities() async throws {
        let wine = try makeFakeEngine()
        let bottle = Bottle(name: "Probe", status: .ready, enginePath: wine.path)
        let engine = WineEngine()
        let result = try await engine.diagnoseGraphics(bottle: bottle, prefix: prefix, probeURL: probe,
            logURL: root.appendingPathComponent("probe.log"), verbose: true)
        XCTAssertTrue(result.supportsDX12FeatureLevel12)
        XCTAssertEqual(result.maximumFeatureLevel, 0xc000)
        XCTAssertEqual(result.shaderModel, 0x66)
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-calls"), encoding: .utf8), "-w\n-k\n-w\n")
        let running = await engine.isRunning(prefix: prefix)
        XCTAssertFalse(running)
    }

    func testDiagnosticRejectsExistingExternalSessionWithoutKillingIt() async throws {
        let wine = try makeFakeEngine()
        try Data().write(to: prefix.appendingPathComponent("existing-session"))
        let bottle = Bottle(name: "Busy", status: .ready, enginePath: wine.path)
        do {
            _ = try await WineEngine().diagnoseGraphics(bottle: bottle, prefix: prefix, probeURL: probe,
                logURL: root.appendingPathComponent("busy.log"), verbose: false)
            XCTFail("An existing session must block diagnosis")
        } catch PorticoError.busy { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("existing-session").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("wine-called").path))
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-calls"), encoding: .utf8), "-w\n")
    }

    func testResolverRejectsMissingReceiptAndUnknownProvider() throws {
        XCTAssertThrowsError(try GraphicsRuntimeLocation.resolve(reference: "portico-graphics://gptk-3.0-3", rootURL: root))
        XCTAssertThrowsError(try GraphicsRuntimeLocation.resolve(reference: "portico-graphics://gptk-3.0-3/../other", rootURL: root))
        XCTAssertThrowsError(try GraphicsRuntimeLocation.reference(providerID: "../other"))
    }

    func testManagedVersionProbeUsesActualProcessWithValidatedReceipt() async throws {
        let wine = try makeManagedFixture()
        // This test app has no signature. A distribution signature assessment must
        // not replace the OS decision made when the bounded process is launched.
        let version = try await WineEngine(graphicsRoot: root).probe(executable: wine)
        XCTAssertEqual(version, "wine-7.7 (Portico fixture)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wine.path + ".called"))
    }

    func testManagedVersionProbeStillRejectsMissingReceiptBeforeExecution() async throws {
        let wine = try makeManagedFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("gptk-3.0-3/.download.json"))
        do {
            _ = try await WineEngine(graphicsRoot: root).probe(executable: wine)
            XCTFail("A managed provider without its receipt must not run")
        } catch { XCTAssertTrue(error is PorticoError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wine.path + ".called"))
    }

    func testInitializationDeadlineStopsAHungWinebootBeforeUnlocking() async throws {
        try await checkInitializationDeadline(detached: false)
    }

    func testInitializationDeadlineAlsoBoundsDetachedServerWait() async throws {
        try await checkInitializationDeadline(detached: true)
    }

    func testStopAcceptsAlreadyIdleWineSevenServerAfterSuccessfulWait() async throws {
        let wine = try makeFakeEngine()
        try script(wine.deletingLastPathComponent().appendingPathComponent("wineserver"), #"""
        #!/bin/sh
        printf '%s\n' "$1" >> "$WINEPREFIX/server-calls"
        if [ "$1" = "-k" ]; then exit 1; fi
        exit 0
        """#)
        let bottle = Bottle(name: "Idle", status: .ready, enginePath: wine.path)
        let engine = WineEngine()
        try await engine.stop(bottle: bottle, prefix: prefix)
        try await engine.stop(bottle: bottle, prefix: prefix)
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-calls"), encoding: .utf8), "-k\n-w\n-k\n-w\n")
        let caps = try await engine.diagnoseGraphics(bottle: bottle, prefix: prefix, probeURL: probe,
            logURL: root.appendingPathComponent("already-idle-probe.log"), verbose: false)
        XCTAssertTrue(caps.supportsDX12FeatureLevel12, "Probe cleanup has the same already-idle race")
    }

    func testStopRejectsKillOneWhenWaitDoesNotConfirmIdle() async throws {
        let wine = try makeFakeEngine()
        try script(wine.deletingLastPathComponent().appendingPathComponent("wineserver"), #"""
        #!/bin/sh
        printf '%s\n' "$1" >> "$WINEPREFIX/server-calls"
        if [ "$1" = "-k" ]; then exit 1; fi
        printf 'cannot confirm idle\n' >&2
        exit 7
        """#)
        do {
            try await WineEngine().stop(bottle: Bottle(name: "Wait fails", status: .ready, enginePath: wine.path), prefix: prefix)
            XCTFail("A failed wait must not turn kill1 into success")
        } catch PorticoError.processFailed(let code, let output) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(output.contains("cannot confirm idle"))
        }
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-calls"), encoding: .utf8), "-k\n-w\n")
    }

    func testStopPreservesKillOneWithErrorOutput() async throws {
        let wine = try makeFakeEngine()
        try script(wine.deletingLastPathComponent().appendingPathComponent("wineserver"), #"""
        #!/bin/sh
        printf '%s\n' "$1" >> "$WINEPREFIX/server-calls"
        printf 'permission failure\n' >&2
        exit 1
        """#)
        do {
            try await WineEngine().stop(bottle: Bottle(name: "Kill fails", status: .ready, enginePath: wine.path), prefix: prefix)
            XCTFail("A substantive kill failure must be preserved")
        } catch PorticoError.processFailed(let code, let output) {
            XCTAssertEqual(code, 1)
            XCTAssertTrue(output.contains("permission failure"))
        }
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("server-calls"), encoding: .utf8), "-k\n")
    }

    /// Opt-in only: the installer must have produced this Graphics root and receipt.
    /// Each invocation creates a new prefix and never reads or changes a user's bottle.
    func testInstalledGPTKInitializesDiagnosesAndLaunchesProbe() async throws {
        guard let location = ProcessInfo.processInfo.environment["PORTICO_DX12_INTEGRATION_ROOT"] else {
            throw XCTSkip("Set PORTICO_DX12_INTEGRATION_ROOT to an installed Graphics directory for the real runtime test.")
        }
        let graphicsRoot = URL(fileURLWithPath: location)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let work = workspace.appendingPathComponent("work/dx12-integration/\(UUID().uuidString)", isDirectory: true)
        let isolatedPrefix = work.appendingPathComponent("prefix", isDirectory: true)
        let executable = workspace.appendingPathComponent("Assets/Diagnostics/d3d12-probe.exe")
        let engine = WineEngine(graphicsRoot: graphicsRoot)
        var bottle = Bottle(name: "Isolated DX12 integration", enginePath: try GraphicsRuntimeLocation.reference(providerID: GraphicsRuntimeCatalog.appleGPTK3.id),
            graphics: BottleGraphics(backend: .d3dMetal, providerID: GraphicsRuntimeCatalog.appleGPTK3.id))
        let wine = try GraphicsRuntimeLocation.resolve(reference: bottle.enginePath, rootURL: graphicsRoot)
        let version: String
        do { version = try await engine.probe(executable: wine) }
        catch {
            throw XCTSkip("The installed GPTK version probe could not execute. Real integration was not completed: \(error.localizedDescription)")
        }
        XCTAssertTrue(version.contains("wine-7.7"), "The full GPTK provider must use its paired Wine7.7 bridge")
        do {
            let boot = try await engine.initialize(bottle: bottle, prefix: isolatedPrefix,
                logURL: work.appendingPathComponent("boot.log"), verbose: false)
            XCTAssertEqual(boot.exitCode, 0)
            bottle.status = .ready
            let capabilities = try await engine.diagnoseGraphics(bottle: bottle, prefix: isolatedPrefix, probeURL: executable,
                logURL: work.appendingPathComponent("diagnose.log"), verbose: false)
            XCTAssertTrue(capabilities.supportsDX12FeatureLevel12)
            XCTAssertGreaterThanOrEqual(capabilities.shaderModel ?? 0, 0x60)
            let game = Game(name: "Windowless D3D12 probe", bottleID: bottle.id, executablePath: executable.path)
            let launched = try await engine.launch(game: game, bottle: bottle, prefix: isolatedPrefix,
                logURL: work.appendingPathComponent("launch.log"), verbose: false)
            XCTAssertEqual(launched.exitCode, 0)
            XCTAssertTrue(try GraphicsCapabilities.parse(launched.output).supportsDX12FeatureLevel12)
        } catch {
            try? await engine.stop(bottle: bottle, prefix: isolatedPrefix)
            throw error
        }
        try await engine.stop(bottle: bottle, prefix: isolatedPrefix)
    }

    private func makeFakeEngine() throws -> URL {
        let wine = root.appendingPathComponent("engine/wine")
        try script(wine, #"""
        #!/bin/sh
        /usr/bin/touch "$WINEPREFIX/wine-called"
        printf 'PORTICO_D3D12_CAPABILITY_PROBE_V1\n'
        printf 'provider=C:\\windows\\system32\\d3d12.dll\n'
        printf 'create requested=0x0000c000 hr=0x00000000 device=yes\n'
        printf 'feature_levels_hr=0x00000000\nmaximum_feature_level=0x0000c000\n'
        printf 'shader requested=0x00000068 hr=0x00000000 maximum=0x00000066\n'
        printf 'PROBE_COMPLETE\n'
        """#)
        try script(wine.deletingLastPathComponent().appendingPathComponent("wineserver"), #"""
        #!/bin/sh
        printf '%s\n' "$1" >> "$WINEPREFIX/server-calls"
        if [ "$1" = "-k" ]; then /bin/rm -f "$WINEPREFIX/existing-session"; fi
        if [ "$1" = "-w" ]; then
          while [ -f "$WINEPREFIX/existing-session" ]; do /bin/sleep 0.02; done
        fi
        """#)
        return wine
    }

    private func checkInitializationDeadline(detached: Bool) async throws {
        let wine = try makeFakeEngine()
        let body = detached ? "exit 0" : "while :; do /bin/sleep 0.02; done"
        try script(wine, "#!/bin/sh\n/usr/bin/touch \"$WINEPREFIX/existing-session\"\n\(body)\n")
        let engine = WineEngine(initializationTimeout: 0.15)
        let bottle = Bottle(name: "Bounded initialization", enginePath: wine.path)
        do {
            _ = try await engine.initialize(bottle: bottle, prefix: prefix,
                logURL: root.appendingPathComponent("initialize-timeout.log"), verbose: false)
            XCTFail("Initialization must stop at its deadline")
        } catch PorticoError.runtimeUnavailable { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("existing-session").path))
        let calls = try String(contentsOf: prefix.appendingPathComponent("server-calls"), encoding: .utf8)
        XCTAssertTrue(calls.hasSuffix("-k\n-w\n"), "Timeout cleanup must finish before unlocking")
        let running = await engine.isRunning(prefix: prefix)
        XCTAssertFalse(running)
    }

    private func makeManagedFixture() throws -> URL {
        let release = GraphicsRuntimeCatalog.appleGPTK3
        let directory = root.appendingPathComponent(release.id, isDirectory: true)
        let runtime = directory.appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine", isDirectory: true)
        let wine = runtime.appendingPathComponent("bin/wine64")
        let server = runtime.appendingPathComponent("bin/wineserver")
        try script(wine, #"""
        #!/bin/sh
        /usr/bin/touch "$0.called"
        printf 'wine-7.7 (Portico fixture)\n'
        """#)
        try script(server, "#!/bin/sh\nexit 0\n")
        for path in [
            "lib/wine/x86_64-windows/d3d12.dll", "lib/wine/x86_64-windows/d3d11.dll", "lib/wine/x86_64-windows/dxgi.dll",
            "lib/external/libd3dshared.dylib", "lib/external/D3DMetal.framework/D3DMetal",
            "lib/GStreamer.framework/Versions/1.0/lib/libgstreamer-1.0.0.dylib",
            "lib/GStreamer.framework/Versions/1.0/libexec/gstreamer-1.0/gst-plugin-scanner"
        ] { try script(runtime.appendingPathComponent(path), "test fixture only\n") }
        let receipt: [String: Any] = [
            "schemaVersion": 1, "providerID": release.id, "version": release.version,
            "sourceURL": release.sourceURL.absoluteString, "archiveURL": release.downloadURL.absoluteString,
            "archiveSHA256": release.sha256, "archiveBytes": release.downloadBytes,
            "archiveRoot": "Game Porting Toolkit.app", "executableRelativePath": "Contents/Resources/wine/bin/wine64",
            "wineSHA256": try RuntimeInstaller.sha256(of: wine), "wineserverSHA256": try RuntimeInstaller.sha256(of: server),
            "appleSignaturesVerified": true, "codeModified": false
        ]
        try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent(".download.json"))
        return wine
    }

    private func script(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
    }
}
