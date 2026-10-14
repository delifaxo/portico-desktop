import Foundation
import Darwin
import XCTest
@testable import PorticoCore

final class GraphicsRuntimeInstallerTests: XCTestCase {
    private var temporary: URL!
    private var app: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PorticoGraphicsInstaller-" + UUID().uuidString)
        app = temporary.appendingPathComponent("Game Porting Toolkit.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testTreeClosureAcceptsFrameworkStyleRelativeLinks() throws {
        let framework = app.appendingPathComponent("D3DMetal.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: version.appendingPathComponent("D3DMetal"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path,
                                                  withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("D3DMetal").path,
                                                  withDestinationPath: "Versions/Current/D3DMetal")
        XCTAssertNoThrow(try GraphicsRuntimeInstaller.validateTreeClosure(at: app))
    }

    func testTreeClosureRejectsEscapingFileAndDirectoryLinks() throws {
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("dependency.dylib")
        try Data("external".utf8).write(to: file)
        let link = app.appendingPathComponent("linked")
        for target in [file, outside] {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try GraphicsRuntimeInstaller.validateTreeClosure(at: app))
            try FileManager.default.removeItem(at: link)
        }
    }

    func testTreeClosureRejectsDanglingAndCyclicLinks() throws {
        let link = app.appendingPathComponent("linked")
        for destination in ["missing", "linked"] {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            XCTAssertThrowsError(try GraphicsRuntimeInstaller.validateTreeClosure(at: app))
            try FileManager.default.removeItem(at: link)
        }
    }

    func testTreeClosureRejectsSpecialFilesWithoutOpeningThem() throws {
        let fifo = app.appendingPathComponent("pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try GraphicsRuntimeInstaller.validateTreeClosure(at: app))
    }

    func testExtractedProviderRejectsWineOrServerSymlinkEvenInsideApp() throws {
        let bin = app.appendingPathComponent("Contents/Resources/wine/bin")
        let external = app.appendingPathComponent("Contents/Resources/wine/lib/external")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external.appendingPathComponent("D3DMetal.framework"), withIntermediateDirectories: true)
        try Data("not Apple code".utf8).write(to: external.appendingPathComponent("libd3dshared.dylib"))
        let wine = bin.appendingPathComponent("wine64")
        let server = bin.appendingPathComponent("wineserver")
        for file in [wine, server] {
            try Data("not executable code".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        }
        // This validation does not claim an Apple signature; install checks that separately.
        XCTAssertNoThrow(try GraphicsRuntimeInstaller.validateExtractedProvider(at: temporary))
        for file in [wine, server] {
            let original = bin.appendingPathComponent("original-" + file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: original)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
            XCTAssertThrowsError(try GraphicsRuntimeInstaller.validateExtractedProvider(at: temporary))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: original, to: file)
        }
    }

    #if !APP_STORE
    func testExecutionAssessmentRejectsUnexpectedPathBeforeSystemAssessment() async throws {
        let file = temporary.appendingPathComponent("wine64")
        try Data("not executable code".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        do {
            try await GraphicsRuntimeInstaller.assessExecution(executableURL: file)
            XCTFail("A standalone executable is not a complete GPTK package")
        } catch RuntimeInstallError.invalidArchive { }
        catch { XCTFail("Expected path validation before spctl: \(error)") }
    }

    func testExecutionAssessmentRejectsEscapingBinBeforeSystemAssessment() async throws {
        let wineRoot = app.appendingPathComponent("Contents/Resources/wine")
        try FileManager.default.createDirectory(at: wineRoot, withIntermediateDirectories: true)
        let outside = temporary.appendingPathComponent("outside-bin")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for name in ["wine64", "wineserver"] {
            let file = outside.appendingPathComponent(name)
            try Data("not executable code".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        }
        try FileManager.default.createSymbolicLink(at: wineRoot.appendingPathComponent("bin"), withDestinationURL: outside)
        do {
            try await GraphicsRuntimeInstaller.assessExecution(executableURL: wineRoot.appendingPathComponent("bin/wine64"))
            XCTFail("A provider executable may not escape through a directory link")
        } catch RuntimeInstallError.invalidArchive { }
        catch { XCTFail("Expected containment validation before spctl: \(error)") }
    }

    func testInvalidExistingReceiptIsRetainedWithoutDownloadingOrReplacing() async throws {
        let destination = temporary.appendingPathComponent(GraphicsRuntimeCatalog.appleGPTK3.id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let receipt = destination.appendingPathComponent(".download.json")
        let invalid = Data("{}".utf8)
        try invalid.write(to: receipt)
        do {
            _ = try await GraphicsRuntimeInstaller().install(rootURL: temporary, progress: { _ in })
            XCTFail("Invalid receipt must fail before downloads or extraction")
        } catch {
            XCTAssertEqual(try Data(contentsOf: receipt), invalid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Downloads").path))
        }
    }
    #endif
}
