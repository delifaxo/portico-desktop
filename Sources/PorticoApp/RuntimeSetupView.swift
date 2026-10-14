import SwiftUI
import AppKit
import PorticoCore

@MainActor
extension AppModel {
    func restoreDownloadedWine() {
        guard downloadedWineApp == nil, !DistributionPolicy.isAppStore, let store else { return }
        let folder = store.rootURL.appendingPathComponent("Runtimes/\(RuntimeCatalog.wine.id)")
        let app = folder.appendingPathComponent(RuntimeCatalog.wine.archiveRoot)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".download.json").path),
           FileManager.default.fileExists(atPath: app.path) { downloadedWineApp = app }
    }
    var gstreamerVersion: String? {
        let framework = URL(fileURLWithPath: "/Library/Frameworks/GStreamer.framework")
        let info = Bundle(url: framework)?.infoDictionary
        return info?["CFBundleShortVersionString"] as? String
            ?? (FileManager.default.fileExists(atPath: framework.path) ? L10n.text("встановлено") : nil)
    }
    var rosettaAvailable: Bool {
        #if arch(arm64)
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        #else
        return true
        #endif
    }
    func downloadWine() {
        guard activeDownload == nil, !DistributionPolicy.isAppStore, let store else { return }
        activeDownload = "wine"; setupError = nil; setupFinished = false
        setupProgress = InstallProgress(stage: "downloading", fraction: 0)
        setupTask = Task {
            defer { activeDownload = nil; setupTask = nil }
            do {
                let wine = try await runtimeInstaller.install(release: RuntimeCatalog.wine, rootURL: store.rootURL) { [weak self] progress in
                    Task { @MainActor in self?.setupProgress = progress }
                }
                downloadedWineApp = wine.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                enginePathDraft = wine.path
                await probeEngine()
                if engineReady { setupFinished = true; setupProgress = InstallProgress(stage: "installed", fraction: 1) }
                else { setupError = "Файли Wine підготовлено, але рушій ще не пройшов перевірку запуску. Перевірте компоненти та повідомлення про помилку." }
            } catch is CancellationError {
                setupProgress = nil; setupError = "Завантаження скасовано. Його можна почати знову."
            } catch RuntimeInstallError.securityAssessmentFailed(let appURL, let details) {
                downloadedWineApp = appURL
                setupProgress = nil
                setupError = "Wine завантажено й перевірено за SHA-256. macOS поки не дозволила його запуск. Файли збережено — їх можна показати у Finder.\n\n\(details)"
            } catch {
                setupProgress = nil; setupError = LocalizedMessage(verbatim: error.localizedDescription)
            }
        }
    }
    func downloadGStreamer() {
        guard activeDownload == nil, !DistributionPolicy.isAppStore, let store else { return }
        activeDownload = "gstreamer"; setupError = nil
        setupProgress = InstallProgress(stage: "downloading", fraction: 0)
        setupTask = Task {
            defer { activeDownload = nil; setupTask = nil }
            do {
                downloadedGStreamer = try await runtimeInstaller.downloadArtifact(
                    url: RuntimeCatalog.gstreamerURL,
                    sha256: RuntimeCatalog.gstreamerSHA256,
                    expectedBytes: RuntimeCatalog.gstreamerBytes,
                    destination: store.rootURL.appendingPathComponent("Downloads/gstreamer-1.0-\(RuntimeCatalog.gstreamerVersion)-universal.pkg")
                ) { [weak self] progress in Task { @MainActor in self?.setupProgress = progress } }
                setupProgress = nil
            } catch is CancellationError {
                setupProgress = nil; setupError = "Завантаження скасовано. Його можна почати знову."
            } catch { setupProgress = nil; setupError = LocalizedMessage(verbatim: error.localizedDescription) }
        }
    }
    func revealDownloadedWine() {
        if let downloadedWineApp { NSWorkspace.shared.activateFileViewerSelecting([downloadedWineApp]) }
    }
    func openGStreamerInstaller() {
        if let downloadedGStreamer { NSWorkspace.shared.open(downloadedGStreamer) }
    }
}

struct RuntimeSetupView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "door.left.hand.open").font(.system(size: 21))
                    Text("Portico").font(.system(size: 21, weight: .bold, design: .rounded))
                }.foregroundStyle(Palette.mint)
                Spacer(minLength: 5)
                PortalArtwork().frame(width: 215, height: 220).scaleEffect(0.8).offset(x: -9)
                Text(L10n.text("Ваша гра.\nВаш Mac."))
                    .font(.system(size: 32, weight: .semibold)).tracking(-1.2)
                Text(L10n.text("Кілька компонентів —\nі можна створювати перше\nігрове середовище."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
                Spacer(minLength: 25)
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive").font(.system(size: 10))
                    Text(L10n.text("Ігри зберігаються на вашому Mac")).font(.system(size: 9))
                }.foregroundStyle(Palette.muted)
            }.padding(28).frame(width: 270)
                .background(LinearGradient(colors: [Color(hex: 0x253632), Color(hex: 0x171F22)], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L10n.text("ПЕРШИЙ ЗАПУСК")).font(.system(size: 8, weight: .semibold)).tracking(1.6).foregroundStyle(Palette.mint)
                    Spacer()
                    LanguagePicker(model: model)
                    Button { model.sheet = nil } label: { Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Palette.muted) }.buttonStyle(.plain).help(L10n.text("Закрити налаштування"))
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.setupFinished ? L10n.text("Усе готово до старту") : L10n.text("Підготуємо Mac до гри"))
                        .font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                    Text(model.hasBundledRuntime || DistributionPolicy.isAppStore ? L10n.text("Підготовка вбудованого рушія та ігрового середовища.") : L10n.text("Завантажте Wine тут або підключіть уже встановлений рушій."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
                if model.hasBundledRuntime || DistributionPolicy.isAppStore {
                    BundledRuntimeCard(model: model)
                } else {
                    wineCard
                    dependenciesCard
                }
                if let progress = model.setupProgress, model.activeDownload != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(stageTitle(progress.stage)).font(.system(size: 11, weight: .medium))
                            Spacer()
                            if let fraction = progress.fraction { Text("\(Int(max(0, min(1, fraction)) * 100)) %").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.mint) }
                            Button(L10n.text("Скасувати")) { model.setupTask?.cancel() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        if let fraction = progress.fraction { ProgressView(value: max(0, min(1, fraction))).tint(Palette.mint) }
                        else { ProgressView().controlSize(.small) }
                    }.padding(.vertical, 3)
                }
                if let error = model.setupError {
                    ScrollView {
                        Text(L10n.text(error)).font(.system(size: 11)).foregroundStyle(Palette.amber).lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 88)
                }
                if model.downloadedWineApp != nil && !model.engineReady {
                    HStack(spacing: 14) {
                        Button { model.revealDownloadedWine() } label: { Label(L10n.text("Показати Wine"), systemImage: "folder") }
                        Button { model.downloadWine() } label: { Label(L10n.text("Перевірити знову"), systemImage: "arrow.clockwise") }.disabled(model.activeDownload != nil)
                    }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.mint)
                }
                Spacer(minLength: 0)
                HStack {
                    Button(L10n.text("Пізніше")) { model.sheet = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    if model.engineReady {
                        Button { model.sheet = .createBottle } label: { Label(L10n.text("Створити середовище"), systemImage: "arrow.right") }.buttonStyle(PorticoButtonStyle(primary: true))
                    } else if !DistributionPolicy.isAppStore {
                        Button(L10n.text("Wine уже встановлено")) { model.sheet = nil; model.section = .runtime; model.chooseEngine() }
                            .buttonStyle(PorticoButtonStyle()).disabled(model.activeDownload != nil)
                    }
                }
            }.padding(28).frame(width: 532)
                .background(Palette.sidebar)
        }.frame(height: 645).preferredColorScheme(.dark)
            .onAppear { model.restoreDownloadedWine() }
    }

    private var wineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.mint).frame(width: 38, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Wine Stable 11.0").font(.system(size: 15, weight: .semibold))
                    Text(L10n.text("Windows API · 185 МБ · Intel / Rosetta")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if model.engineReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint) }
            }
            Text(L10n.text("Відкрита збірка Gcenx. Після завантаження Portico перевірить SHA-256 і дозвіл macOS на запуск."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            HStack {
                if model.engineReady {
                    Label(L10n.text("Рушій підключено"), systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.mint)
                } else {
                    Button { model.downloadWine() } label: { Label(model.activeDownload == "wine" ? L10n.text("Завантаження…") : L10n.text("Завантажити Wine"), systemImage: "arrow.down.circle") }
                        .buttonStyle(PorticoButtonStyle(primary: true)).disabled(model.activeDownload != nil)
                }
                Spacer()
                Button { model.openURL(RuntimeCatalog.wine.sourceURL.absoluteString) } label: { Label(L10n.text("Джерело"), systemImage: "arrow.up.right") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(18).setupCard()
    }

    private var dependenciesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Palette.muted).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GStreamer").font(.system(size: 12, weight: .medium))
                    Text(model.gstreamerVersion.map { L10n.text("Виявлено версію \($0)") } ?? L10n.text("Медіакомпонент Wine · 152 МБ"))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if model.downloadedGStreamer != nil {
                    Button(L10n.text("Встановити…")) { model.openGStreamerInstaller() }.buttonStyle(PorticoButtonStyle())
                } else {
                    Button(L10n.text("Завантажити 1.28.1")) { model.downloadGStreamer() }.buttonStyle(PorticoButtonStyle()).disabled(model.activeDownload != nil)
                }
            }
            if model.downloadedGStreamer != nil {
                Text(L10n.text("Пакет перевірено. Встановлення завершує стандартний інсталятор macOS."))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Divider()
            HStack(spacing: 11) {
                Image(systemName: "cpu").foregroundStyle(Palette.muted).frame(width: 22)
                Text("Rosetta 2").font(.system(size: 12, weight: .medium))
                Spacer()
                Label(model.rosettaAvailable ? L10n.text("Доступна") : L10n.text("Потрібна на Apple Silicon"), systemImage: model.rosettaAvailable ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(model.rosettaAvailable ? Palette.mint : Palette.amber)
            }
        }.padding(16).setupCard()
    }

    private func stageTitle(_ stage: String) -> String {
        switch stage {
        case "downloading": return L10n.text("Завантажуємо \(model.activeDownload == "gstreamer" ? "GStreamer" : "Wine")")
        case "verifying": return L10n.text("Перевіряємо контрольну суму")
        case "extracting": return L10n.text("Розпаковуємо рушій")
        case "assessing": return L10n.text("Перевіряємо дозвіл macOS")
        case "installed": return L10n.text("Рушій готовий")
        default: return L10n.text("Готуємо файли")
        }
    }
}

private extension View {
    func setupCard() -> some View {
        self.background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
    }
}
