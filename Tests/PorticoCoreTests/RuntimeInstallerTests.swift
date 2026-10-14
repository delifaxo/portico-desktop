import Foundation
import XCTest
@testable import PorticoCore

final class RuntimeInstallerTests: XCTestCase {
    private var temporaryURL: URL!
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("PorticoInstallerTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL { try FileManager.default.removeItem(at: temporaryURL) }
    }

    private func release(id: String = "wine-stable-11.0_1", sha: String? = nil, bytes: Int64 = 3,
                         archiveRoot: String = "Wine Stable.app", executable: String = "Contents/Resources/wine/bin/wine64",
                         download: String = "https://github.com/Gcenx/macOS_Wine_builds/releases/download/test/wine.tar.xz") -> RuntimeRelease {
        RuntimeRelease(id: id, name: "Wine Stable", version: "11.0_1", downloadURL: URL(string: download)!,
                       sha256: sha ?? abcDigest, downloadBytes: bytes, archiveRoot: archiveRoot,
                       executableRelativePath: executable, sourceURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/test")!)
    }

    private func createPair(_ release: RuntimeRelease) throws -> (wine: URL, server: URL) {
        let wine = temporaryURL.appendingPathComponent(release.archiveRoot).appendingPathComponent(release.executableRelativePath)
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        for file in [wine, server] {
            // These fixtures are never executed. Their permission bits exercise path validation.
            try Data("test fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        }
        return (wine, server)
    }

    func testPinnedMetadataWithVersionSuffixIsValid() throws {
        XCTAssertNoThrow(try RuntimeInstaller.validateMetadata(release()))
        XCTAssertNoThrow(try RuntimeInstaller.validateMetadata(release(sha: abcDigest.uppercased())))
    }

    func testDownloadHostsRequireHTTPSAndExactAllowlist() throws {
        for url in ["https://github.com/release", "https://release-assets.githubusercontent.com/file",
                    "https://objects.githubusercontent.com/file", "https://gstreamer.freedesktop.org/data/pkg/osx/file.pkg",
                    DirectXLegacyRuntime.url.absoluteString] {
            XCTAssertNoThrow(try RuntimeInstaller.validateDownloadURL(URL(string: url)!))
        }
        for url in ["http://github.com/release", "https://github.com.evil.example/release",
                    "https://evil.example/file", "file:///tmp/runtime", "https://user:secret@github.com/file", "https://github.com:444/file",
                    "https://download.microsoft.com.evil.example/redist.exe", "http://download.microsoft.com/redist.exe"] {
            XCTAssertThrowsError(try RuntimeInstaller.validateDownloadURL(URL(string: url)!))
        }
    }

    func testReleaseIdentifiersCannotEscapeRuntimeFolder() throws {
        for id in ["", "../outside", "/outside", ".hidden", "a..b", "wine/stable", "wine\\stable", "wine\nversion"] {
            XCTAssertThrowsError(try RuntimeInstaller.validateMetadata(release(id: id)))
        }
    }

    func testMissingChecksumOrUnboundedSizeIsRejected() throws {
        for checksum in ["", "unknown", String(repeating: "a", count: 63), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try RuntimeInstaller.validateMetadata(release(sha: checksum)))
        }
        let invalidSizes: [Int64] = [0, -1, 8 * 1024 * 1024 * 1024 + 1]
        for bytes in invalidSizes {
            XCTAssertThrowsError(try RuntimeInstaller.validateMetadata(release(bytes: bytes)))
        }
    }

    func testAppAndExecutableMetadataRejectTraversal() throws {
        for root in ["../Wine.app", "/Wine.app", "Wine.app/", "./Wine.app", "folder/Wine.app", "Wine.zip"] {
            XCTAssertThrowsError(try RuntimeInstaller.validateMetadata(release(archiveRoot: root)))
        }
        for executable in ["/bin/wine", "Contents/../bin/wine", "Contents/bin/other", "Contents/bin/wine/../../outside"] {
            XCTAssertThrowsError(try RuntimeInstaller.validateMetadata(release(executable: executable)))
        }
    }

    func testArchiveListingAcceptsSpacesAndLeadingDot() throws {
        XCTAssertNoThrow(try RuntimeInstaller.validateArchiveEntries([
            "./", "./Wine Stable.app/", "./Wine Stable.app/Contents/Resources/wine/bin/wine64",
            "Wine Stable.app/Contents/Resources/wine/bin/wineserver", ""
        ], expectedRoot: "Wine Stable.app"))
    }

    func testArchiveListingRejectsAbsoluteParentAndForeignEntries() throws {
        for entry in ["/tmp/outside", "../outside", "Wine Stable.app/../../outside", "Other.app/Contents",
                      "Wine Stable.app/C:/outside", "Wine Stable.app/Contents\\outside", "Wine Stable.app/name\nsecond"] {
            XCTAssertThrowsError(try RuntimeInstaller.validateArchiveEntries([entry], expectedRoot: "Wine Stable.app"))
        }
        XCTAssertThrowsError(try RuntimeInstaller.validateArchiveEntries(["", "./"], expectedRoot: "Wine Stable.app"))
    }

    func testStreamingSHA256MatchesKnownDigest() throws {
        let file = temporaryURL.appendingPathComponent("artifact")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try RuntimeInstaller.sha256(of: file), abcDigest)
        XCTAssertNoThrow(try RuntimeInstaller.verifyArtifact(at: file, sha256: abcDigest, expectedBytes: 3))
    }

    func testIntegrityChecksRejectIncompleteOversizeAndModifiedFile() throws {
        let file = temporaryURL.appendingPathComponent("artifact")
        try Data("abc".utf8).write(to: file)
        XCTAssertThrowsError(try RuntimeInstaller.verifyArtifact(at: file, sha256: abcDigest, expectedBytes: 2))
        XCTAssertThrowsError(try RuntimeInstaller.verifyArtifact(at: file, sha256: abcDigest, expectedBytes: 4))
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try RuntimeInstaller.verifyArtifact(at: file, sha256: abcDigest, expectedBytes: 3))
    }

    func testArtifactSymlinkIsNotAcceptedAsVerifiedDownload() throws {
        let original = temporaryURL.appendingPathComponent("original")
        let link = temporaryURL.appendingPathComponent("artifact")
        try Data("abc".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try RuntimeInstaller.verifyArtifact(at: link, sha256: abcDigest, expectedBytes: 3))
    }

    func testExtractedRuntimeRequiresExecutableWineAndServerInsideApp() throws {
        let metadata = release()
        let pair = try createPair(metadata)
        XCTAssertEqual(try RuntimeInstaller.validateExtractedRuntime(at: temporaryURL, release: metadata).resolvingSymlinksInPath(), pair.wine.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: pair.server)
        XCTAssertThrowsError(try RuntimeInstaller.validateExtractedRuntime(at: temporaryURL, release: metadata))
    }

    func testExtractedRuntimeRejectsNonExecutablePair() throws {
        let metadata = release()
        let pair = try createPair(metadata)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: pair.wine.path)
        XCTAssertThrowsError(try RuntimeInstaller.validateExtractedRuntime(at: temporaryURL, release: metadata))
    }

    func testExtractedWineCannotResolveOutsideApp() throws {
        let metadata = release()
        let pair = try createPair(metadata)
        let external = temporaryURL.appendingPathComponent("outside-wine")
        try FileManager.default.moveItem(at: pair.wine, to: external)
        try FileManager.default.createSymbolicLink(at: pair.wine, withDestinationURL: external)
        XCTAssertThrowsError(try RuntimeInstaller.validateExtractedRuntime(at: temporaryURL, release: metadata))
    }

    func testExtractedServerCannotResolveOutsideApp() throws {
        let metadata = release()
        let pair = try createPair(metadata)
        let external = temporaryURL.appendingPathComponent("outside-server")
        try FileManager.default.moveItem(at: pair.server, to: external)
        try FileManager.default.createSymbolicLink(at: pair.server, withDestinationURL: external)
        XCTAssertThrowsError(try RuntimeInstaller.validateExtractedRuntime(at: temporaryURL, release: metadata))
    }

    func testAppDirectoryCannotBeASymlink() throws {
        let metadata = release()
        _ = try createPair(metadata)
        let app = temporaryURL.appendingPathComponent(metadata.archiveRoot)
        let elsewhere = temporaryURL.appendingPathComponent("Elsewhere.app")
        try FileManager.default.moveItem(at: app, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try RuntimeInstaller.validateExtractedRuntime(at: temporaryURL, release: metadata))
    }

    func testSecurityRejectionCarriesRetainedApplicationPath() throws {
        let app = temporaryURL.appendingPathComponent("Wine Stable.app")
        let error = RuntimeInstallError.securityAssessmentFailed(appURL: app, details: "rejected")
        guard case .securityAssessmentFailed(let retained, let details) = error else { return XCTFail("Expected security rejection") }
        XCTAssertEqual(retained, app)
        XCTAssertEqual(details, "rejected")
        XCTAssertTrue(error.localizedDescription.contains(app.path))
    }
}
