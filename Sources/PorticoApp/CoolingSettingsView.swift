import SwiftUI
import PorticoCore

struct CoolingSettingsView: View {
    @ObservedObject var cooling: CoolingController
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Налаштування")).font(.system(size: 30, weight: .bold))
                Text(L10n.text("Тема та мова інтерфейсу.")).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 18) {
                Label(L10n.text("Оформлення"), systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                HStack {
                    Text(L10n.text("Тема оформлення"))
                    Spacer()
                    ThemePicker(model: model, showsLabels: true)
                }
                HStack {
                    Text(L10n.text("Мова інтерфейсу"))
                    Spacer()
                    LanguagePicker(model: model)
                }
            }.padding(25).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.separator, lineWidth: 1))
            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.text("Лічильник FPS"), systemImage: "speedometer")
                    .font(.system(size: 20, weight: .semibold))
                HStack {
                    Text(L10n.text("Показувати FPS в іграх"))
                    Spacer()
                    Toggle(L10n.text("Показувати FPS в іграх"), isOn: Binding(
                        get: { model.library.settings.showFPS }, set: model.setShowFPS))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(model.storageProblem != nil)
                        .accessibilityIdentifier("fps-counter-toggle")
                }
                Text(L10n.text("Показує FPS і показники Metal поверх гри. Працює в іграх з Metal/D3DMetal; для ігор без Metal лічильник недоступний. Після зміни перезапустіть гру та її Steam або CrossOver."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(25)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.separator, lineWidth: 1))
            VStack(alignment: .leading, spacing: 20) {
                Label(L10n.text("Охолодження"), systemImage: "fanblades")
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.text("Автоматичний профіль Portico +20%"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.text("Оберти залежать від температури CPU та GPU. Portico додає 20% до власної температурної кривої, у межах максимуму вентилятора. Це не надбавка до автоматики macOS і не обіцянка зниження температури на 20%."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Image(systemName: cooling.state == .active ? "fanblades.fill" : "circle")
                        .foregroundStyle(cooling.state == .active ? Palette.mint : Palette.muted)
                    Text(statusText).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if cooling.state == .authorizing || cooling.state == .starting || cooling.state == .stopping { ProgressView().controlSize(.small) }
                    Toggle(L10n.text("Увімкнути охолодження +20%"), isOn: Binding(
                        get: { cooling.state == .authorizing || cooling.state == .starting || cooling.state == .active },
                        set: { $0 ? cooling.start() : cooling.stop() }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(cooling.state == .stopping || (cooling.state == .off && !cooling.canStart))
                        .accessibilityIdentifier("cooling-boost-toggle")
                }
                if let snapshot = cooling.snapshot {
                    Divider()
                    HStack(spacing: 30) {
                        metric("CPU", value: "\(Int(snapshot.cpuTemperature.rounded())) °C")
                        metric("GPU", value: "\(Int(snapshot.gpuTemperature.rounded())) °C")
                        ForEach(snapshot.fans) { fan in
                            metric(L10n.text("Вентилятор \(fan.id + 1)"), value: "\(Int(fan.actualRPM.rounded())) RPM")
                        }
                    }
                    if cooling.state == .off && !snapshot.isSystemAutomatic {
                        Label(L10n.text("Вентиляторами вже керує інша програма. Поверніть у ній режим Auto, потім повторіть."), systemImage: "info.circle")
                            .font(.system(size: 12)).foregroundStyle(Palette.amber)
                    }
                }
                if let error = cooling.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled)
                    if !cooling.diagnostic.isEmpty {
                        Text(cooling.diagnostic).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.muted).textSelection(.enabled)
                    }
                } else if cooling.helperURL == nil {
                    Text(CoolingError.helperMissing.localizedDescription).font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
                if cooling.state == .off && cooling.snapshot?.isSystemAutomatic == false {
                    Button(L10n.text("Повернути автоматику macOS")) { cooling.restoreAutomatic() }
                        .buttonStyle(PorticoButtonStyle()).disabled(cooling.isRestoring)
                        .accessibilityIdentifier("cooling-restore-auto")
                    if cooling.isRestoring { ProgressView().controlSize(.small) }
                }
                Divider()
                Text(L10n.text("Діє на весь Mac, поки Portico відкрито. Увімкнення потребує дозволу адміністратора. Після вимкнення, виходу або переходу в сон керування повертається macOS. Після запуску Portico профіль потрібно ввімкнути знову."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Базова крива: від мінімальних обертів при 40 °C до максимальних при 80 °C, потім +20%. Використовується найгарячіший датчик CPU або GPU. Вентилятори можуть стати гучнішими."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(25)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.separator, lineWidth: 1))
        }
        .task {
            while !Task.isCancelled {
                cooling.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private var statusText: String {
        switch cooling.state {
        case .off: return cooling.snapshot?.isSystemAutomatic == true ? L10n.text("Автоматика macOS") : L10n.text("Профіль Portico вимкнено")
        case .authorizing: return L10n.text("Очікування дозволу адміністратора…")
        case .starting: return L10n.text("Запуск профілю…")
        case .active: return L10n.text("Охолодження +20% увімкнено")
        case .stopping: return L10n.text("Повернення до автоматики macOS…")
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 19, weight: .medium, design: .monospaced))
        }
    }
}
