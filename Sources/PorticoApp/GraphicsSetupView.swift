import SwiftUI
import PorticoCore

struct GraphicsRuntimeCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: "cube.transparent.fill").font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.mint).frame(width: 58, height: 58)
                .background(Palette.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 10) {
                Text("DirectX 12 → Metal").font(.system(size: 21, weight: .semibold))
                Text(L10n.text("Окремий рушій D3DMetal із перевіркою графічних можливостей вашого Mac."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Text(L10n.text("Зовнішній рушій використовується на умовах його правовласника. Підключення в Portico не надає додаткових прав."))
                    .font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                if DistributionPolicy.isAppStore {
                    Text(L10n.text("Цей компонент недоступний у профілі App Store.")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    HStack(spacing: 14) {
                        Button { model.beginDX12Bottle() } label: {
                            Label(model.graphicsInstalled ? L10n.text("Налаштувати DirectX 12") : L10n.text("Підключити DirectX 12…"),
                                  systemImage: model.graphicsInstalled ? "plus" : "folder.badge.plus")
                        }.buttonStyle(PorticoButtonStyle(primary: true)).accessibilityIdentifier("graphics-setup-open")
                        Text(model.graphicsInstalled ? L10n.text("Рушій підключено") : L10n.text("Встановлюється користувачем"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(25).background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.mint.opacity(0.16)))
    }
}

struct GraphicsSetupView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("DirectX 12 → Metal", systemImage: "cube.transparent.fill")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.mint)
                Spacer()
                Button { model.sheet = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Закрити"))
            }
            Text(L10n.text("Отримайте й встановіть рушій самостійно, а потім підключіть його в Portico. Перед запуском гри нове середовище пройде перевірку DirectX 12."))
                .font(.system(size: 13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("1. Відкрийте сайт Apple та ознайомтеся з умовами вибраної версії GPTK."))
                Text(L10n.text("2. Підготуйте повний сумісний комплект Wine + D3DMetal у постійній папці на Mac."))
                Text(L10n.text("3. Підключіть застосунок або папку wine. Portico збереже шлях та перевірить запуск."))
                Text(L10n.text("Одного DMG або D3DMetal.framework недостатньо. Portico не збирає комплект з окремих бібліотек і не підключає їх до вбудованого Wine 11."))
                    .foregroundStyle(Palette.muted)
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
            Text(L10n.text("Зовнішній рушій використовується на умовах його правовласника. Підключення в Portico не надає додаткових прав."))
                .font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Link(L10n.text("Завантажити D3DMetal…"), destination: LocalGraphicsRuntime.appleDownloadPage)
                    .accessibilityIdentifier("graphics-apple-page")
                Button(L10n.text("Підключити локальний рушій")) { model.chooseLocalGraphics() }
                    .buttonStyle(PorticoButtonStyle(primary: true))
                    .disabled(DistributionPolicy.isAppStore || model.activeDownload != nil || model.assessingGraphics)
                    .accessibilityIdentifier("graphics-connect-local")
            }.font(.system(size: 12))
            Text(L10n.text("Відкриє Apple Developer у браузері. Вхід, прийняття умов і завантаження виконує користувач."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let path = model.localGraphicsPath {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    .textSelection(.enabled).lineLimit(3).accessibilityIdentifier("graphics-local-path")
            }
            if model.connectingGraphics {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Перевірка локального комплекту та підписів Apple…")).font(.system(size: 12))
                }.accessibilityIdentifier("graphics-local-progress")
            }
            if let error = model.graphicsError {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("graphics-install-error")
            }
            if let issue = model.graphicsSecurityIssue {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.text("Не вдалося запустити рушій"), systemImage: "lock.shield")
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.text("Компоненти встановлено, але перевірку запуску не завершено. Якщо macOS показала попередження, перегляньте його й дозволи в системних параметрах, а потім повторіть перевірку."))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.text("Подробиці помилки")) {
                        ScrollView { Text(issue).font(.system(size: 11)).textSelection(.enabled) }.frame(maxHeight: 100)
                    }.font(.system(size: 11))
                    HStack(spacing: 16) {
                        Button(L10n.text("Показати у Finder")) { model.revealGraphicsRuntime() }.buttonStyle(.plain)
                        Link(L10n.text("Довідка Apple"), destination: URL(string: "https://support.apple.com/102445")!)
                    }.font(.system(size: 12))
                }.foregroundStyle(Palette.amber).padding(16)
                    .background(Palette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("graphics-gatekeeper-blocked")
            }
            HStack {
                Button(L10n.text("Пізніше")) { model.sheet = nil }.buttonStyle(PorticoButtonStyle())
                Spacer()
                if model.assessingGraphics {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Перевірка запуску рушія…")).font(.system(size: 12))
                } else if model.connectingGraphics {
                    Button(L10n.text("Скасувати підключення")) { model.setupTask?.cancel() }.buttonStyle(PorticoButtonStyle())
                } else if model.graphicsInstalled && model.graphicsExecutionAllowed {
                    Button(L10n.text("Створити середовище DX12")) { model.beginDX12Bottle() }
                        .buttonStyle(PorticoButtonStyle(primary: true)).accessibilityIdentifier("graphics-create-bottle")
                } else if model.graphicsInstalled {
                    Button(L10n.text("Перевірити запуск")) { Task { await model.assessGraphics() } }
                        .buttonStyle(PorticoButtonStyle(primary: true)).accessibilityIdentifier("graphics-security-recheck")
                }
            }
        }.padding(30).frame(width: 620).background(Palette.sidebar).task { await model.assessGraphics() }
    }
}

struct GraphicsBottleStatus: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.transparent").foregroundStyle(Palette.mint)
            VStack(alignment: .leading, spacing: 5) {
                Text("DirectX 12 · D3DMetal").font(.system(size: 12, weight: .medium))
                if let report = model.graphicsReports[bottle.id] {
                    Text("Feature Level \(report.maximumFeatureLevelLabel ?? "—") · Shader Model \(report.shaderModelLabel ?? "—")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(report.supportsDX12FeatureLevel12 ? Palette.mint : Palette.amber)
                    Text(L10n.text("Результат останньої перевірки. Сумісність гри перевіряється окремим запуском."))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else {
                    Text(L10n.text("Графічні можливості ще не перевірено.")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            Button(L10n.text("Перевірити DX12")) { model.diagnoseGraphics(in: bottle) }
                .buttonStyle(PorticoButtonStyle()).disabled(bottle.status != .ready || model.isBusy(bottle))
                .accessibilityIdentifier("graphics-probe-\(bottle.id.uuidString)")
        }.padding(15).background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
