import Foundation

public enum FeedbackKind: String, Codable, CaseIterable, Sendable {
    case crash, suggestion
}

/// A report is created for review; this type never uploads in the background.
public struct CrashReport: Codable, Identifiable, Sendable {
    public var id: String { clientReportId }
    public var clientReportId: String
    public var source = "macos"
    public var title: String
    public var description: String
    public var appVersion: String
    public var osVersion: String
    public var architecture: String
    public var diagnostics: String
    public var consent: Bool
    public var kind: FeedbackKind
    public var publicConsent: Bool

    public init(title: String, description: String, appVersion: String, diagnostics: String, consent: Bool = false, id: UUID = UUID(), kind: FeedbackKind = .crash, publicConsent: Bool = false) {
        clientReportId = id.uuidString.lowercased()
        self.title = title; self.description = description; self.appVersion = appVersion
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "x86_64"
        #endif
        self.diagnostics = diagnostics; self.consent = consent
        self.kind = kind; self.publicConsent = publicConsent
    }
}

public enum CrashReporting {
    public static let endpoint = URL(string: "https://185.233.45.102:8443/api/v1/crashes")!
    public static let suggestionsEndpoint = URL(string: "https://185.233.45.102:8443/api/v1/suggestions")!
    public static func boardURL(kind: FeedbackKind, id: String? = nil) -> URL {
        var url = URLComponents(string: "https://185.233.45.102:8443/" + (kind == .suggestion ? "suggestions" : "crashes"))!
        if let id { url.queryItems = [URLQueryItem(name: "report", value: id)] }
        return url.url!
    }
    public static let maximumDiagnostics = 262144

    /// Collect a bounded, redacted preview locally. This does not perform network I/O.
    public static func reviewDiagnostics(context: [String], log: String) -> String {
        let header = String(decoding: redact(context.joined(separator: "\n")).utf16.prefix(8000), as: UTF16.self)
        let tail = String(decoding: redact(log).utf16.suffix(48000), as: UTF16.self)
        return ["Portico diagnostics", header, "--- Wine log ---", tail].joined(separator: "\n\n")
    }

    public static func redact(_ value: String) -> String {
        let replacements: [(String, String)] = [
            (#"/(?:Users|home)/[^/\s"\\]+"#, "/Users/[redacted]"),
            (#"C:\\Users\\[^\\\s"]+"#, #"C:\\Users\\[redacted]"#),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email redacted]"),
            (#"\b(Bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[redacted]"),
            (#"((?:password|passwd|token|secret|api[_-]?key|authorization|cookie)["']?\s*[:=]\s*["']?)[^\s"',;]+"#, "$1[redacted]")
        ]
        return replacements.reduce(value) { result, item in
            result.replacingOccurrences(of: item.0, with: item.1, options: [.regularExpression, .caseInsensitive])
        }
    }

    /// Select only native Portico reports, never other apps' diagnostics.
    public static func recentNativeCrash(in directory: URL? = nil, now: Date = Date()) -> String? {
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return nil }
        let candidates = files.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix("Portico-"), ["ips", "crash"].contains(url.pathExtension),
                  let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true, info.isSymbolicLink != true,
                  let date = info.contentModificationDate, date > now.addingTimeInterval(-7 * 86400) else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in candidates {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let headerData = try? handle.read(upToCount: 16384) else { continue }
            let header = String(decoding: headerData, as: UTF8.self)
            let identity = #""(?:app_name|procName)"\s*:\s*"Portico"|Process:\s+Portico\s+\["#
            guard header.range(of: identity, options: .regularExpression) != nil else { continue }
            guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: size > 196608 ? size - 196608 : 0)) != nil,
                  let tail = try? handle.readToEnd() else { continue }
            return redact(String(decoding: tail, as: UTF8.self))
        }
        return nil
    }

    public static func send(_ report: CrashReport, to destination: URL? = nil, session: URLSession = .shared) async throws -> String {
        guard report.consent else { throw CrashReportError.consentRequired }
        let endpoint = destination ?? (report.kind == .suggestion ? suggestionsEndpoint : self.endpoint)
        guard endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil else { throw CrashReportError.invalidEndpoint }
        guard !report.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !report.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              report.title.utf16.count <= 200, report.description.utf16.count <= 6000,
              report.diagnostics.utf16.count <= maximumDiagnostics else { throw CrashReportError.invalidReport }
        var clean = report
        clean.title = redact(clean.title); clean.description = redact(clean.description); clean.diagnostics = redact(clean.diagnostics)
        if clean.kind == .suggestion { clean.diagnostics = "" }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(clean)
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, [200, 201].contains(response.statusCode) else {
            throw CrashReportError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Receipt: Decodable { let id: String; let status: String }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.status == "received",
              UUID(uuidString: receipt.id) != nil,
              receipt.id.caseInsensitiveCompare(report.clientReportId) == .orderedSame else { throw CrashReportError.invalidReceipt }
        return receipt.id
    }
}

public enum CrashReportError: LocalizedError {
    case consentRequired, invalidEndpoint, invalidReport, invalidReceipt, rejected(Int)
    public var errorDescription: String? {
        let en = AppLanguage.saved() == .english
        switch self {
        case .consentRequired: return en ? "Review the report and confirm your consent." : "Перегляньте звіт і підтвердьте згоду."
        case .invalidEndpoint: return en ? "A secure HTTPS report endpoint is required." : "Для звітів потрібна захищена HTTPS-адреса."
        case .invalidReport: return en ? "Enter a title and description. The report must fit the size limit." : "Додайте заголовок і опис. Звіт має відповідати обмеженню розміру."
        case .invalidReceipt: return en ? "The server did not confirm receipt. Try again." : "Сервер не підтвердив отримання. Спробуйте ще раз."
        case .rejected(let status): return en ? "Report not accepted (HTTP \(status)). Your text is preserved; try again later." : "Звіт не прийнято (HTTP \(status)). Текст збережено; спробуйте пізніше."
        }
    }
}
