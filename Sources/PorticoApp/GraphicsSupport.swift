import Foundation
import AppKit
import PorticoCore

extension AppModel {
    var graphicsRoot: URL? { store?.rootURL.appendingPathComponent("Graphics", isDirectory: true) }
    var connectingGraphics: Bool { activeDownload == "graphics" }

    func offerGraphicsOnFirstLaunch() {
        guard section != .setup, !DistributionPolicy.isAppStore, engineReady, sheet == nil, !hasShownGraphicsWelcome,
              !graphicsInstalled, let root = store?.rootURL else { return }
        let marker = root.appendingPathComponent(".graphics-welcome-shown")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        hasShownGraphicsWelcome = true
        try? Data("1".utf8).write(to: marker, options: .atomic)
        sheet = .graphicsSetup
    }

    func refreshGraphics() {
        guard !DistributionPolicy.isAppStore else { graphicsInstalled = false; graphicsExecutionAllowed = false; return }
        let selection = LocalGraphicsRuntime.selectedProviderID(rootURL: graphicsRoot) ?? GraphicsRuntimeCatalog.appleGPTK3.id
        if graphicsProviderID != selection { graphicsExecutionAllowed = false }
        graphicsProviderID = selection
        let executable = try? GraphicsRuntimeLocation.resolve(
            reference: GraphicsRuntimeLocation.reference(providerID: selection), rootURL: graphicsRoot)
        graphicsInstalled = executable != nil
        localGraphicsPath = executable?.deletingLastPathComponent().deletingLastPathComponent().path
        if !graphicsInstalled { graphicsExecutionAllowed = false }
        // Reports remain on disk for diagnostics, but only this app session's
        // measurements appear in the UI: a library can migrate to another Mac.
    }

    func chooseLocalGraphics() {
        guard !DistributionPolicy.isAppStore, activeDownload == nil, !assessingGraphics, let graphicsRoot else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Підключити локальний рушій")
        panel.message = L10n.text("Виберіть повний встановлений комплект Wine + D3DMetal. Portico перевірить його та збереже шлях, не копіюючи файли.")
        panel.prompt = L10n.text("Підключити")
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let selection = panel.url else { return }
        activeDownload = "graphics"; graphicsError = nil; graphicsSecurityIssue = nil
        setupTask = Task {
            defer { activeDownload = nil; setupTask = nil; refreshGraphics() }
            do {
                _ = try await LocalGraphicsRuntime.connect(selection: selection, rootURL: graphicsRoot)
                graphicsExecutionAllowed = false
                refreshGraphics()
                await assessGraphics()
            } catch is CancellationError {
                graphicsError = L10n.text("Підключення скасовано. Попередній рушій збережено.")
            } catch { graphicsError = error.localizedDescription }
        }
    }

    func beginDX12Bottle() {
        refreshGraphics()
        newBottleGraphics = .d3dMetal
        sheet = graphicsInstalled && graphicsExecutionAllowed ? .createBottle : .graphicsSetup
    }

    func assessGraphics() async {
        guard !assessingGraphics, !DistributionPolicy.isAppStore else { return }
        refreshGraphics()
        guard graphicsInstalled else { return }
        assessingGraphics = true; graphicsExecutionAllowed = false; graphicsSecurityIssue = nil
        defer { assessingGraphics = false }
        do {
            let executable = try GraphicsRuntimeLocation.resolve(
                reference: GraphicsRuntimeLocation.reference(providerID: graphicsProviderID), rootURL: graphicsRoot)
            // Gatekeeper's user-approved launch can succeed while static spctl
            // signature assessment still rejects the unsigned upstream wrapper.
            // Execute the pinned runtime through the normal macOS process path.
            _ = try await engine.probe(executable: executable)
            try Task.checkCancellation()
            graphicsExecutionAllowed = true
        } catch is CancellationError { }
        catch { graphicsSecurityIssue = error.localizedDescription }
    }

    func revealGraphicsRuntime() {
        guard let path = localGraphicsPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func runGraphicsProbe(in bottle: Bottle) async throws -> GraphicsCapabilities {
        guard let store, let file = graphicsReportURL(for: bottle) else {
            throw PorticoError.invalidInput(L10n.text("Бібліотека недоступна"))
        }
        // Delete the previous result before testing; a failed retry must not look successful.
        graphicsReports[bottle.id] = nil
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let probe = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Diagnostics/d3d12-probe.exe")
        let report = try await engine.diagnoseGraphics(bottle: bottle, prefix: store.prefixURL(for: bottle),
            probeURL: probe, logURL: store.logURL(for: bottle), verbose: library.settings.verboseLogging)
        try Task.checkCancellation()
        let saved = SavedGraphicsReport(engineReference: bottle.enginePath,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, checkedAt: Date(), capabilities: report)
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        graphicsReports[bottle.id] = report
        return report
    }

    private func graphicsReportURL(for bottle: Bottle) -> URL? {
        store?.logURL(for: bottle).deletingPathExtension().appendingPathExtension("graphics.json")
    }
}

private struct SavedGraphicsReport: Codable {
    let engineReference: String
    let osVersion: String
    let checkedAt: Date
    let capabilities: GraphicsCapabilities
}
