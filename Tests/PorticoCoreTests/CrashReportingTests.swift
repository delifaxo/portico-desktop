import Foundation
import XCTest
@testable import PorticoCore

final class CrashReportingTests: XCTestCase {
    func testLocalPreviewRedactsContextAndKeepsTheRecentLogWithinTheLimit() {
        let preview = CrashReporting.reviewDiagnostics(
            context: ["Section: library", "/Users/alice/Game", "token=context-secret"],
            log: "OLD LOG START\n" + String(repeating: "старий рядок 🎮\n", count: 10000)
                + "RECENT LOG END\nBearer recent-secret\nalice@example.invalid")
        XCTAssertTrue(preview.contains("Section: library"))
        XCTAssertTrue(preview.contains("RECENT LOG END"))
        XCTAssertFalse(preview.contains("OLD LOG START"))
        for privateValue in ["alice", "context-secret", "recent-secret", "example.invalid"] {
            XCTAssertFalse(preview.contains(privateValue), privateValue)
        }
        XCTAssertLessThan(preview.utf16.count, CrashReporting.maximumDiagnostics)
    }

    func testDeliverySendsOnlyTheReviewedPayloadAndRequiresItsOwnReceipt() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReportTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ReportTestProtocol.handler = nil }
        let report = CrashReport(title: "QA", description: "Synthetic steps", appVersion: "qa",
                                 diagnostics: "token=synthetic-secret", consent: true)
        ReportTestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                data = body
            }
            let submitted = try JSONDecoder().decode(CrashReport.self, from: data)
            XCTAssertEqual(submitted.description, "Synthetic steps")
            XCTAssertEqual(submitted.clientReportId, report.clientReportId)
            XCTAssertFalse(submitted.diagnostics.contains("synthetic-secret"))
            XCTAssertTrue(submitted.consent)
            return Data("{\"id\":\"\(report.clientReportId)\",\"status\":\"received\"}".utf8)
        }
        let id = try await CrashReporting.send(report, to: URL(string: "https://portico.test/crashes")!, session: session)
        XCTAssertEqual(id, report.clientReportId)
        ReportTestProtocol.handler = { _ in
            Data("{\"id\":\"\(UUID().uuidString)\",\"status\":\"received\"}".utf8)
        }
        do {
            _ = try await CrashReporting.send(report, to: URL(string: "https://portico.test/crashes")!, session: session)
            XCTFail("A receipt for a different report must not count as delivered")
        } catch { guard case CrashReportError.invalidReceipt = error else { return XCTFail("Wrong error: \(error)") } }
    }

    func testCancelledSubmissionDoesNotStartANetworkRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReportTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ReportTestProtocol.handler = nil }
        ReportTestProtocol.handler = { _ in XCTFail("Cancelled submissions must not upload"); return Data() }
        let report = CrashReport(title: "QA", description: "Synthetic", appVersion: "qa", diagnostics: "", consent: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CrashReporting.send(report, to: URL(string: "https://portico.test/crashes")!, session: session)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSuggestionUsesItsOwnEndpointAndNeverUploadsDiagnostics() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReportTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ReportTestProtocol.handler = nil }
        let report = CrashReport(title: "Idea", description: "Synthetic suggestion", appVersion: "qa",
                                 diagnostics: "PRIVATE_LOG", consent: true, kind: .suggestion, publicConsent: true)
        ReportTestProtocol.handler = { request in
            XCTAssertEqual(request.url, CrashReporting.suggestionsEndpoint)
            let stream = request.httpBodyStream
            var data = request.httpBody ?? Data()
            if let stream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let submitted = try JSONDecoder().decode(CrashReport.self, from: data)
            XCTAssertEqual(submitted.kind, .suggestion)
            XCTAssertTrue(submitted.publicConsent)
            XCTAssertEqual(submitted.diagnostics, "")
            return Data("{\"id\":\"\(report.clientReportId)\",\"status\":\"received\"}".utf8)
        }
        let receipt = try await CrashReporting.send(report, session: session)
        XCTAssertEqual(receipt, report.clientReportId)
        XCTAssertEqual(CrashReporting.boardURL(kind: .suggestion, id: receipt).path, "/suggestions")
        XCTAssertEqual(URLComponents(url: CrashReporting.boardURL(kind: .suggestion, id: receipt), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, receipt)
    }

    func testLiveReceiverWhenExplicitlyConfigured() async throws {
        guard let address = ProcessInfo.processInfo.environment["PORTICO_CRASH_QA_URL"], let url = URL(string: address) else {
            throw XCTSkip("Set PORTICO_CRASH_QA_URL to run the synthetic HTTPS delivery check")
        }
        guard url == CrashReporting.endpoint else { return XCTFail("The explicit QA destination must match the app endpoint") }
        let report = CrashReport(title: "[QA] Native Portico delivery check", description: "Synthetic report from CrashReportingTests. No real user diagnostics.", appVersion: "0.3.10-qa", diagnostics: "/Users/qa-person/Library/synthetic.log\ntoken=qa-secret\nqa@example.invalid", consent: true)
        let receipt = try await CrashReporting.send(report)
        XCTAssertEqual(receipt, report.clientReportId)
        print("PORTICO_QA_RECEIPT=\(receipt)")
    }

    func testRedactsPathsAndCredentialsBeforeTransmission() {
        let clean = CrashReporting.redact("/Users/alice/Library/log.txt\n/home/bob/log\nC:\\Users\\carol\\game\nBearer abc123\npassword=secret-value\n{\"token\":\"token-value\"}\nalice@example.com")
        for value in ["alice", "bob", "carol", "abc123", "secret-value", "token-value", "example.com"] { XCTAssertFalse(clean.contains(value), value) }
        XCTAssertTrue(clean.contains("/Library/log.txt"))
    }

    func testOnlyRecentPorticoNativeReportsAreSelected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"app_name":"OtherApp"}"#.write(to: dir.appendingPathComponent("Portico-other.ips"), atomically: true, encoding: .utf8)
        try #"{"app_name":"PorticoCoolingHelper"}"#.write(to: dir.appendingPathComponent("Portico-helper.ips"), atomically: true, encoding: .utf8)
        XCTAssertNil(CrashReporting.recentNativeCrash(in: dir))
        let native = dir.appendingPathComponent("Portico-native.ips")
        try #"{"app_name":"Portico","path":"/Users/alice/Applications/Portico.app"}"#.write(to: native, atomically: true, encoding: .utf8)
        let report = try XCTUnwrap(CrashReporting.recentNativeCrash(in: dir))
        XCTAssertFalse(report.contains("alice")); XCTAssertTrue(report.contains("Portico.app"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: native.path)
        XCTAssertNil(CrashReporting.recentNativeCrash(in: dir))
    }

    func testNoNetworkWithoutConsentOrHTTPS() async throws {
        var report = CrashReport(title: "Crash", description: "Steps", appVersion: "test", diagnostics: "")
        do { _ = try await CrashReporting.send(report); XCTFail("Must require consent") }
        catch { guard case CrashReportError.consentRequired = error else { return XCTFail("Wrong error: \(error)") } }
        report.consent = true
        do { _ = try await CrashReporting.send(report, to: URL(string: "http://example.com/crashes")!); XCTFail("Must require HTTPS") }
        catch { guard case CrashReportError.invalidEndpoint = error else { return XCTFail("Wrong error: \(error)") } }
    }
}

private final class ReportTestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler?(request) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
