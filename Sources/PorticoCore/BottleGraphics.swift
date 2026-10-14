import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case wineDefault
    case d3dMetal

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .wineDefault: return L10n.text("Графіка Wine (типово)")
        case .d3dMetal: return L10n.text("D3DMetal")
        }
    }
}

/// A provider identity is persisted instead of an arbitrary filesystem path.
/// Selecting a backend does not assert that its components or Wine compatibility have been verified.
public struct BottleGraphics: Codable, Equatable, Sendable {
    public var backend: GraphicsBackend
    public var providerID: String?

    public init(backend: GraphicsBackend = .wineDefault, providerID: String? = nil) {
        self.backend = backend; self.providerID = providerID
    }

    public func validate() throws {
        switch backend {
        case .wineDefault:
            guard providerID == nil else {
                throw PorticoError.invalidInput(L10n.text("Для стандартної графіки Wine окремий графічний компонент не вибирається."))
            }
        case .d3dMetal:
            guard let providerID, GraphicsRuntimeCatalog.provider(id: providerID) != nil || LocalGraphicsRuntime.isLocalProvider(providerID) else {
                throw PorticoError.invalidInput(L10n.text("Для D3DMetal виберіть відомий випуск графічних компонентів. Довільні шляхи та невідомі ідентифікатори не підтримуються."))
            }
        }
    }
}
