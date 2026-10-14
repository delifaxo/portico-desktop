import Foundation
import XCTest
import Darwin
import CoolingSMC
@testable import PorticoCore

final class CoolingTests: XCTestCase {
    func testAddsTwentyPercentToCurveRatherThanFeedback() throws {
        // At 60°C the base curve is halfway between 1000 and 5000: 3000 RPM.
        let target = try XCTUnwrap(CoolingPolicy.targetRPM(temperature: 60, minimum: 1000, maximum: 5000))
        XCTAssertEqual(target, 3600)
        var current = target
        for _ in 0..<100 {
            current = try XCTUnwrap(CoolingPolicy.targetRPM(temperature: 60, minimum: 1000, maximum: 5000, previous: current))
        }
        XCTAssertEqual(current, 3600, "The boost must never compound")
    }
    func testNeverExceedsEachFansHardwareMaximum() throws {
        for temperature in stride(from: 1.0, through: 125.0, by: 0.5) {
            for maximum in [5000.0, 5777.9] {
                let target = try XCTUnwrap(CoolingPolicy.targetRPM(temperature: temperature, minimum: 1350.2, maximum: maximum))
                XCTAssertGreaterThanOrEqual(target, 1350.2)
                XCTAssertLessThanOrEqual(target, maximum)
            }
        }
    }
    func testTemperatureRiseAndThermalPressureTakePriority() {
        XCTAssertEqual(CoolingPolicy.targetRPM(temperature: 80, minimum: 1000, maximum: 5000, previous: 1200), 5000)
        XCTAssertEqual(CoolingPolicy.targetRPM(temperature: 45, minimum: 1000, maximum: 5000, previous: 1200, thermalEmergency: true), 5000)
        XCTAssertEqual(CoolingPolicy.targetRPM(temperature: 60, minimum: 1000, maximum: 5000, previous: 1200), 3600)
    }
    func testSpeedDropsGraduallyAfterTemperatureFalls() {
        XCTAssertEqual(CoolingPolicy.targetRPM(temperature: 40, minimum: 1000, maximum: 5000, previous: 4000), 3900)
        XCTAssertEqual(CoolingPolicy.targetRPM(temperature: 40, minimum: 1000, maximum: 5000, previous: 1250), 1200)
    }
    func testInvalidSensorsAndLimitsFailClosed() {
        for temperature in [Double.nan, .infinity, -.infinity, 0, -10, 126] {
            XCTAssertNil(CoolingPolicy.targetRPM(temperature: temperature, minimum: 1000, maximum: 5000))
        }
        XCTAssertNil(CoolingPolicy.targetRPM(temperature: 60, minimum: 5000, maximum: 1000))
        XCTAssertNil(CoolingPolicy.targetRPM(temperature: 60, minimum: -1, maximum: 5000))
        XCTAssertNil(CoolingPolicy.targetRPM(temperature: 60, minimum: 1000, maximum: .nan))
    }
    func testLeaseRevocationAndExpiry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lease = folder.appendingPathComponent("lease")
        XCTAssertTrue(FileManager.default.createFile(atPath: lease.path, contents: Data("active\n".utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid(), getpid()), 1)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15)], ofItemAtPath: lease.path)
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid(), getpid()), 0)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: lease.path)
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid(), getpid()), 0)
        try FileManager.default.removeItem(at: lease)
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid(), getpid()), 0)
    }
    func testLeaseRejectsSymlinksUnsafePermissionsAndDifferentOwner() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lease = folder.appendingPathComponent("lease")
        let link = folder.appendingPathComponent("link")
        XCTAssertTrue(FileManager.default.createFile(atPath: lease.path, contents: Data("active\n".utf8), attributes: [.posixPermissions: 0o600]))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: lease)
        XCTAssertEqual(pfc_lease_valid(link.path, getuid(), getpid()), 0)
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid() + 1, getpid()), 0)
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid(), 0), 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lease.path)
        XCTAssertEqual(pfc_lease_valid(lease.path, getuid(), getpid()), 0)
    }
    func testCoolingCopyIsTranslated() {
        XCTAssertEqual(L10n.text("Охолодження", language: .english), "Cooling")
        XCTAssertEqual(L10n.text("Охолодження", language: .ukrainian), "Охолодження")
    }
}
