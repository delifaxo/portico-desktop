import Foundation

/// Results from a completed Portico D3D12 probe, not a claim that a particular game works.
public struct GraphicsCapabilities: Codable, Equatable, Sendable {
    public let successfulFeatureLevels: [UInt32]
    public let maximumFeatureLevel: UInt32?
    public let shaderModel: UInt32?

    public var supportsDX12FeatureLevel12: Bool {
        guard let maximumFeatureLevel, Self.requestedFeatureLevels.contains(maximumFeatureLevel),
              maximumFeatureLevel >= 0xc000 else { return false }
        return successfulFeatureLevels.contains { Self.requestedFeatureLevels.contains($0) && $0 >= 0xc000 }
    }
    public var successfulFeatureLevelLabels: [String] { successfulFeatureLevels.map(Self.formatFeatureLevel) }
    public var maximumFeatureLevelLabel: String? { maximumFeatureLevel.map(Self.formatFeatureLevel) }
    public var shaderModelLabel: String? { shaderModel.map(Self.formatShaderModel) }

    public static func formatFeatureLevel(_ value: UInt32) -> String {
        guard requestedFeatureLevels.contains(value) else { return String(format: "0x%08x", value) }
        return "\(value >> 12)_\((value >> 8) & 0xf)"
    }

    public static func formatShaderModel(_ value: UInt32) -> String {
        guard validShaderModel(value) else { return String(format: "0x%08x", value) }
        return "\(value >> 4).\(value & 0xf)"
    }

    public static func parse(_ output: String) throws -> GraphicsCapabilities {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let starts = lines.indices.filter { lines[$0] == "PORTICO_D3D12_CAPABILITY_PROBE_V1" }
        let ends = lines.indices.filter { lines[$0] == "PROBE_COMPLETE" }
        guard starts.count == 1, ends.count == 1, let start = starts.first, let end = ends.first, start < end else {
            throw PorticoError.runtimeUnavailable(L10n.text("Перевірка DirectX 12 не завершилася або її журнал містить неоднозначні результати. Повторіть діагностику."))
        }
        var successes: Set<UInt32> = []
        var maximum: UInt32?
        var shader: UInt32?
        var currentSuccessfulLevel: UInt32?
        var pendingFeatureQuerySucceeded = false
        var sawCreate = false

        for line in lines[(start + 1)..<end] {
            if line.hasPrefix("load_error=") || line.hasPrefix("export_error=") {
                throw PorticoError.runtimeUnavailable(L10n.text("Перевірка не змогла завантажити DirectX 12: \(line)"))
            }
            if line.hasPrefix("create ") {
                let fields = try parseFields(line, prefix: "create ", keys: ["requested", "hr", "device"])
                let requested = try hex(fields["requested"]!)
                let hr = try hex(fields["hr"]!)
                guard requestedFeatureLevels.contains(requested), ["yes", "no"].contains(fields["device"]!) else {
                    throw invalidRecord()
                }
                sawCreate = true
                pendingFeatureQuerySucceeded = false
                // HRESULT uses its high bit for failure. A non-null device is also required.
                if hr & 0x80000000 == 0, fields["device"] == "yes" {
                    successes.insert(requested)
                    currentSuccessfulLevel = requested
                } else { currentSuccessfulLevel = nil }
            } else if line.hasPrefix("feature_levels_hr=") {
                let hr = try hex(String(line.dropFirst("feature_levels_hr=".count)))
                pendingFeatureQuerySucceeded = currentSuccessfulLevel != nil && hr == 0
            } else if line.hasPrefix("maximum_feature_level=") {
                let value = try hex(String(line.dropFirst("maximum_feature_level=".count)))
                if pendingFeatureQuerySucceeded, let createdLevel = currentSuccessfulLevel {
                    guard requestedFeatureLevels.contains(value), value >= createdLevel else { throw invalidRecord() }
                    maximum = max(maximum ?? 0, value)
                }
                // Each maximum must have its own preceding successful query result.
                pendingFeatureQuerySucceeded = false
            } else if line.hasPrefix("shader ") {
                let fields = try parseFields(line, prefix: "shader ", keys: ["requested", "hr", "maximum"])
                let requested = try hex(fields["requested"]!)
                let hr = try hex(fields["hr"]!)
                let value = try hex(fields["maximum"]!)
                if currentSuccessfulLevel != nil, hr == 0 {
                    guard validShaderModel(requested), validShaderModel(value), value <= requested else { throw invalidRecord() }
                    shader = max(shader ?? 0, value)
                }
            }
            // Wine tracing and optional feature records do not establish device capabilities.
        }
        guard sawCreate else { throw invalidRecord() }
        return GraphicsCapabilities(successfulFeatureLevels: successes.sorted(), maximumFeatureLevel: maximum, shaderModel: shader)
    }

    private static let requestedFeatureLevels: Set<UInt32> = [0xb000, 0xb100, 0xc000, 0xc100, 0xc200]

    private static func validShaderModel(_ value: UInt32) -> Bool { value == 0x51 || (0x60...0x68).contains(value) }

    private static func parseFields(_ line: String, prefix: String, keys: Set<String>) throws -> [String: String] {
        var values: [String: String] = [:]
        for item in line.dropFirst(prefix.count).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, keys.contains(String(parts[0])), !parts[1].isEmpty,
                  values.updateValue(String(parts[1]), forKey: String(parts[0])) == nil else { throw invalidRecord() }
        }
        guard Set(values.keys) == keys else { throw invalidRecord() }
        return values
    }

    private static func hex(_ value: String) throws -> UInt32 {
        guard value.hasPrefix("0x") || value.hasPrefix("0X"), value.count > 2, value.count <= 10,
              let number = UInt32(value.dropFirst(2), radix: 16) else { throw invalidRecord() }
        return number
    }

    private static func invalidRecord() -> PorticoError {
        PorticoError.runtimeUnavailable(L10n.text("Журнал перевірки DirectX 12 містить неповні або суперечливі дані. Повторіть діагностику."))
    }
}
