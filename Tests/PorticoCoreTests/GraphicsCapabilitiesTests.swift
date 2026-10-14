import Foundation
import XCTest
@testable import PorticoCore

final class GraphicsCapabilitiesTests: XCTestCase {
    private func completed(_ records: String) -> String {
        "PORTICO_D3D12_CAPABILITY_PROBE_V1\n" + records + "\nPROBE_COMPLETE\n"
    }

    func testActualWine11BaselineDoesNotReportFeatureLevel12() throws {
        let result = try GraphicsCapabilities.parse(Self.actualWine11)
        XCTAssertEqual(result.successfulFeatureLevels, [0xb000])
        XCTAssertEqual(result.maximumFeatureLevel, 0xb000)
        XCTAssertEqual(result.shaderModel, 0x60)
        XCTAssertEqual(result.maximumFeatureLevelLabel, "11_0")
        XCTAssertEqual(result.shaderModelLabel, "6.0")
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testActualGPTK3ResultReportsFeatureLevel12AndShaderModel66() throws {
        let result = try GraphicsCapabilities.parse(Self.actualGPTK3)
        XCTAssertEqual(result.successfulFeatureLevels, [0xb000, 0xb100, 0xc000, 0xc100, 0xc200])
        XCTAssertEqual(result.maximumFeatureLevel, 0xc200)
        XCTAssertEqual(result.shaderModel, 0x66)
        XCTAssertEqual(result.maximumFeatureLevelLabel, "12_2")
        XCTAssertEqual(result.shaderModelLabel, "6.6")
        XCTAssertTrue(result.supportsDX12FeatureLevel12)
    }

    func testSyntheticFeatureLevel12DeviceIsAccepted() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000c000 hr=0x00000000 device=yes
        feature_levels_hr=0x00000000
        maximum_feature_level=0x0000c000
        shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
        """))
        XCTAssertTrue(result.supportsDX12FeatureLevel12)
        XCTAssertEqual(result.successfulFeatureLevelLabels, ["12_0"])
        XCTAssertEqual(result.shaderModel, 0x66)
        XCTAssertEqual(try JSONDecoder().decode(GraphicsCapabilities.self, from: JSONEncoder().encode(result)), result)
    }

    func testFailedCreateWithNonNullPointerDoesNotEstablishCapabilities() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000c200 hr=0x80070057 device=yes
        feature_levels_hr=0x00000000
        maximum_feature_level=0x0000c200
        shader requested=0x00000068 hr=0x00000000 maximum=0x00000068
        """))
        XCTAssertTrue(result.successfulFeatureLevels.isEmpty)
        XCTAssertNil(result.maximumFeatureLevel)
        XCTAssertNil(result.shaderModel)
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testSuccessfulHRESULTWithoutDeviceDoesNotEstablishCapabilities() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000c200 hr=0x00000000 device=no
        feature_levels_hr=0x00000000
        maximum_feature_level=0x0000c200
        shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
        """))
        XCTAssertTrue(result.successfulFeatureLevels.isEmpty)
        XCTAssertNil(result.maximumFeatureLevel)
        XCTAssertNil(result.shaderModel)
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testFailedQueriesCannotUseUnchangedOutputValues() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000c000 hr=0x00000000 device=yes
        feature_levels_hr=0x80070057
        maximum_feature_level=0x0000c200
        shader requested=0x00000068 hr=0x80070057 maximum=0x00000068
        """))
        XCTAssertEqual(result.successfulFeatureLevels, [0xc000])
        XCTAssertNil(result.maximumFeatureLevel)
        XCTAssertNil(result.shaderModel)
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testMaximumRequiresItsOwnSuccessfulQueryStatus() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000b000 hr=0x00000000 device=yes
        feature_levels_hr=0x00000000
        maximum_feature_level=0x0000b000
        maximum_feature_level=0x0000c200
        create requested=0x0000c000 hr=0x00000000 device=yes
        maximum_feature_level=0x0000c200
        """))
        XCTAssertEqual(result.maximumFeatureLevel, 0xb000)
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testFailedNewDeviceCannotReuseEarlierSuccessfulQuery() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000b000 hr=0x00000000 device=yes
        feature_levels_hr=0x00000000
        create requested=0x0000c000 hr=0x80070057 device=no
        maximum_feature_level=0x0000c200
        shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
        """))
        XCTAssertNil(result.maximumFeatureLevel)
        XCTAssertNil(result.shaderModel)
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testReportedMaximumAloneDoesNotReplaceSuccessfulDeviceCreation() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000b000 hr=0x00000000 device=yes
        feature_levels_hr=0x00000000
        maximum_feature_level=0x0000c200
        create requested=0x0000c000 hr=0x80070057 device=no
        """))
        XCTAssertEqual(result.maximumFeatureLevel, 0xc200)
        XCTAssertFalse(result.supportsDX12FeatureLevel12)
    }

    func testShaderModelIsSeparateFromFeatureLevel12Support() throws {
        let result = try GraphicsCapabilities.parse(completed("""
        create requested=0x0000c000 hr=0x00000000 device=yes
        feature_levels_hr=0x00000000
        maximum_feature_level=0x0000c000
        shader requested=0x00000068 hr=0x80070057 maximum=0x00000068
        shader requested=0x00000067 hr=0x00000000 maximum=0x00000060
        """))
        XCTAssertTrue(result.supportsDX12FeatureLevel12)
        XCTAssertEqual(result.shaderModel, 0x60)
        XCTAssertLessThan(try XCTUnwrap(result.shaderModel), 0x66)
    }

    func testMissingDuplicateAndReversedMarkersAreRejected() throws {
        for log in ["", "PORTICO_D3D12_CAPABILITY_PROBE_V1\n", "PROBE_COMPLETE\n",
                    "PROBE_COMPLETE\nPORTICO_D3D12_CAPABILITY_PROBE_V1", Self.actualWine11 + Self.actualWine11,
                    Self.actualGPTK3.replacingOccurrences(of: "PROBE_COMPLETE", with: "")] {
            XCTAssertThrowsError(try GraphicsCapabilities.parse(log))
        }
    }

    func testLoadAndExportFailuresCannotBecomeReady() throws {
        for record in ["load_error=0x0000013d", "export_error=0x0000007f"] {
            XCTAssertThrowsError(try GraphicsCapabilities.parse(completed(record)))
        }
    }

    func testMalformedAndContradictoryCapabilityRecordsAreRejected() throws {
        for records in ["create requested=0x0000c000 hr=broken device=yes",
                        "create requested=0x0000c000 hr=0x00000000 device=maybe",
                        "create requested=0xffffffff hr=0x00000000 device=yes",
                        "create requested=0x0000c000 hr=0x00000000 device=yes\nfeature_levels_hr=0x00000000\nmaximum_feature_level=0x0000b000",
                        "create requested=0x0000c000 hr=0x00000000 device=yes\nshader requested=0x00000066 hr=0x00000000 maximum=0x00000068"] {
            XCTAssertThrowsError(try GraphicsCapabilities.parse(completed(records)))
        }
    }

    // Machine-readable lines captured from the real Wine 11 and GPTK 3 runs.
    // Unrelated Wine trace lines are omitted; the parser also accepts surrounding trace output.
    private static let actualWine11 = #"""
    Wine trace before the probe
    PORTICO_D3D12_CAPABILITY_PROBE_V1
    provider=C:\windows\system32\d3d12.dll
    create requested=0x0000b000 hr=0x00000000 device=yes
    feature_levels_hr=0x00000000
    maximum_feature_level=0x0000b000
    shader requested=0x00000068 hr=0x80070057 maximum=0x00000068
    shader requested=0x00000067 hr=0x00000000 maximum=0x00000060
    create requested=0x0000b100 hr=0x80070057 device=no
    create requested=0x0000c000 hr=0x80070057 device=no
    create requested=0x0000c100 hr=0x80070057 device=no
    create requested=0x0000c200 hr=0x80070057 device=no
    PROBE_COMPLETE
    Wine trace after the probe
    """#

    private static let actualGPTK3 = #"""
    Wine trace before the probe
    PORTICO_D3D12_CAPABILITY_PROBE_V1
    provider=C:\windows\system32\d3d12.dll
    create requested=0x0000b000 hr=0x00000000 device=yes
    feature_levels_hr=0x00000000
    maximum_feature_level=0x0000c200
    shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
    create requested=0x0000b100 hr=0x00000000 device=yes
    feature_levels_hr=0x00000000
    maximum_feature_level=0x0000c200
    shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
    create requested=0x0000c000 hr=0x00000000 device=yes
    feature_levels_hr=0x00000000
    maximum_feature_level=0x0000c200
    shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
    create requested=0x0000c100 hr=0x00000000 device=yes
    feature_levels_hr=0x00000000
    maximum_feature_level=0x0000c200
    shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
    create requested=0x0000c200 hr=0x00000000 device=yes
    feature_levels_hr=0x00000000
    maximum_feature_level=0x0000c200
    shader requested=0x00000068 hr=0x00000000 maximum=0x00000066
    PROBE_COMPLETE
    Wine trace after the probe
    """#
}
