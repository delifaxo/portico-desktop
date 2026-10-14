import Foundation
import CoolingSMC

public struct CoolingFan: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var actualRPM: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    public var targetRPM: Double
    public var mode: Int
}

public struct CoolingSnapshot: Codable, Sendable {
    public var cpuTemperature: Double
    public var gpuTemperature: Double
    public var fans: [CoolingFan]
    public var isSystemAutomatic: Bool

    /// Read-only: visiting Settings never changes SMC state or requests privileges.
    public static func read() throws -> CoolingSnapshot {
        guard !DistributionPolicy.isAppStore else { throw CoolingError.unavailable }
        let connection = pfc_open()
        guard connection != 0 else { throw CoolingError.unavailable }
        defer { pfc_close(connection) }
        var cpu = 0.0, gpu = 0.0
        guard pfc_temperatures(connection, &cpu, &gpu) != 0 else { throw CoolingError.sensors }
        let count = pfc_fan_count(connection)
        guard count > 0 else { throw CoolingError.unavailable }
        let fans = try (0..<count).map { index -> CoolingFan in
            var fan = PFCFan()
            guard pfc_read_fan(connection, index, &fan) != 0 else { throw CoolingError.sensors }
            return CoolingFan(id: Int(index), actualRPM: fan.actual, minimumRPM: fan.minimum,
                maximumRPM: fan.maximum, targetRPM: fan.target, mode: Int(fan.mode))
        }
        return CoolingSnapshot(cpuTemperature: cpu, gpuTemperature: gpu, fans: fans,
            isSystemAutomatic: pfc_is_automatic(connection) != 0)
    }
}

public enum CoolingError: Error, LocalizedError {
    case unavailable, sensors, externalControl, helperMissing, helperFailed, restoreFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("Охолодження Portico доступне у звичайній збірці на Mac з M4 та вентиляторами.")
        case .sensors: return L10n.text("Не вдалося прочитати датчики CPU, GPU або вентиляторів. Профіль зупинено.")
        case .externalControl: return L10n.text("Вентиляторами вже керує інша програма. Поверніть у ній режим Auto, потім повторіть.")
        case .helperMissing: return L10n.text("Помічник охолодження відсутній. Зберіть повний пакет Portico.")
        case .helperFailed: return L10n.text("Профіль охолодження не запущено або його було зупинено. Перевірте дозвіл адміністратора та стан вентиляторів.")
        case .restoreFailed: return L10n.text("Не вдалося підтвердити повернення до автоматики macOS. Перевірте керування вентиляторами.")
        }
    }
}

/// Portico's own curve, not Apple's undocumented automatic target.
/// 40–80°C ramps from hardware minimum to maximum; the hotter CPU/GPU wins.
public enum CoolingPolicy {
    public static let boostMultiplier = 1.2

    public static func targetRPM(temperature: Double, minimum: Double, maximum: Double,
                                 previous: Double? = nil, thermalEmergency: Bool = false) -> Double? {
        guard temperature.isFinite, temperature > 0, temperature <= 125,
              minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum, maximum <= 20_000 else { return nil }
        if thermalEmergency || temperature >= 80 { return maximum }
        let fraction = min(1, max(0, (temperature - 40) / 40))
        let base = minimum + (maximum - minimum) * fraction
        let boosted = min(maximum, max(minimum, (base * boostMultiplier).rounded()))
        // Increase immediately; decrease by at most 100 RPM per one-second sample.
        // Multiplication always uses the curve, never the last boosted output.
        guard let previous, previous.isFinite else { return boosted }
        return min(maximum, max(boosted, previous - 100))
    }
}
