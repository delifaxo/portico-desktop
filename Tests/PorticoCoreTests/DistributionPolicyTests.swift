import XCTest
@testable import PorticoCore

final class DistributionPolicyTests: XCTestCase {
    func testContainmentRejectsSiblingPrefixAndParentTraversal() {
        let bundle = URL(fileURLWithPath: "/Applications/Portico.app", isDirectory: true)
        let runtime = bundle.appendingPathComponent("Contents/Frameworks/WineRuntime", isDirectory: true)
        XCTAssertTrue(DistributionPolicy.containsRuntime(runtime.appendingPathComponent("bin/wine"), in: runtime, bundleDirectory: bundle))
        XCTAssertFalse(DistributionPolicy.containsRuntime(runtime, in: runtime, bundleDirectory: bundle))
        XCTAssertFalse(DistributionPolicy.containsRuntime(URL(fileURLWithPath: runtime.path + "-other/bin/wine"), in: runtime, bundleDirectory: bundle))
        XCTAssertFalse(DistributionPolicy.containsRuntime(runtime.appendingPathComponent("../Other/bin/wine"), in: runtime, bundleDirectory: bundle))
        XCTAssertFalse(DistributionPolicy.containsRuntime(URL(string: "https://example.com/wine")!, in: runtime, bundleDirectory: bundle))
    }

    func testContainmentRejectsRuntimeAndExecutableSymlinksOutsideBundle() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PorticoPolicy-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent("Portico.app", isDirectory: true)
        let runtime = bundle.appendingPathComponent("Contents/Frameworks/WineRuntime", isDirectory: true)
        let outside = temporary.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let externalWine = outside.appendingPathComponent("wine")
        try Data().write(to: externalWine)
        let wineAlias = runtime.appendingPathComponent("wine")
        try FileManager.default.createSymbolicLink(at: wineAlias, withDestinationURL: externalWine)
        XCTAssertFalse(DistributionPolicy.containsRuntime(wineAlias, in: runtime, bundleDirectory: bundle))

        let runtimeAlias = bundle.appendingPathComponent("Contents/Frameworks/LinkedRuntime", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: runtimeAlias, withDestinationURL: outside)
        XCTAssertFalse(DistributionPolicy.containsRuntime(runtimeAlias.appendingPathComponent("wine"), in: runtimeAlias, bundleDirectory: bundle))
    }
}
