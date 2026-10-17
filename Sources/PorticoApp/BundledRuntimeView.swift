import SwiftUI
import AppKit
import PorticoCore

@MainActor
extension AppModel {
    var hasBundledRuntime: Bool {
        (try? RuntimeLocation.resolve(reference: "portico-bundled://" + RuntimeCatalog.wine.id)) != nil
    }

    var bundledRuntimeSummary: String {
        guard let manifest = try? BundledRuntimeManifest.load() else { return "" }
        return manifest.name + (manifest.components?["GStreamer"].map { " · GStreamer " + $0 } ?? "")
    }

    var usingBundledRuntime: Bool {
        engineReady && URL(fileURLWithPath: enginePathDraft).standardizedFileURL.resolvingSymlinksInPath()
            == DistributionPolicy.bundledWineURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func useBundledRuntime() async {
        enginePathDraft = DistributionPolicy.bundledWineURL.path
        await probeEngine()
    }

    func showRuntimeLicenses() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RuntimeLicenses")
        NSWorkspace.shared.open(url)
    }
}

struct BundledRuntimeCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(Palette.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.hasBundledRuntime ? L10n.text("Wine у складі Portico") : L10n.text("Вбудований рушій недоступний")).font(.system(size: 16, weight: .semibold))
                    Text(model.bundledRuntimeSummary)
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: model.usingBundledRuntime ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.usingBundledRuntime ? Palette.mint : Palette.muted)
            }
            Text(model.hasBundledRuntime ? L10n.text("Рушій і медіабібліотеки включено до застосунку. Можна одразу створювати середовище для гри.") : L10n.text("Установіть повну збірку Portico з рушієм."))
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            HStack {
                Label(model.usingBundledRuntime ? L10n.text("Вбудований Wine готовий") : L10n.text("Перевірка запуску рушія"),
                      systemImage: model.usingBundledRuntime ? "checkmark" : "cpu")
                    .font(.system(size: 11)).foregroundStyle(model.usingBundledRuntime ? Palette.mint : Palette.muted)
                Spacer()
                if !model.usingBundledRuntime {
                    Button { Task { await model.useBundledRuntime() } } label: {
                        Text(model.isProbing ? L10n.text("Перевірка…") : L10n.text("Використати вбудований"))
                    }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(model.isProbing || !model.hasBundledRuntime)
                }
            }
            if !model.rosettaAvailable {
                Text(L10n.text("Цій версії Wine потрібна Rosetta 2. Установіть її через системний запит macOS під час першого запуску програми для Intel."))
                    .font(.system(size: 11)).foregroundStyle(Palette.amber).lineSpacing(3)
            }
            HStack {
                Text(L10n.text("Збірка для розробки · сумісність ігор перевіряється окремо"))
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
                Spacer()
                Button(L10n.text("Ліцензії")) { model.showRuntimeLicenses() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.mint)
            }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.separator))
    }
}
