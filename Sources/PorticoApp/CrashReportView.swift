import SwiftUI
import Foundation
import PorticoCore

enum CrashReportText {
    static func text(_ uk: String, _ en: String) -> String { AppLanguage.saved() == .english ? en : uk }
    static let openNotification = Notification.Name("Portico.openCrashReport")
}

@MainActor
extension AppModel {
    /// Capture a local snapshot; neither opening nor cancelling the form sends it.
    func makeCrashReport(error: Notice? = nil, kind: FeedbackKind = .crash) -> CrashReport {
        if kind == .suggestion {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            return CrashReport(title: "", description: "", appVersion: "\(version) (\(build))", diagnostics: "", kind: .suggestion)
        }
        let managed = library.games.first { "game-\($0.id)" == selectedGalleryGameID }
            ?? (selectedGalleryGameID == nil ? filteredGames.first : nil)
        let external = crossOverGames.first { "crossover-\($0.id)" == selectedGalleryGameID }
        let selectedBottle = managed.flatMap { bottle(for: $0) }
        let logBottle = library.bottles.first { $0.id == logBottleID }
        let bottle = error != nil || section == .logs ? logBottle ?? selectedBottle : selectedBottle ?? (external == nil ? logBottle : nil)
        var context = ["Section: \(section.rawValue)", "Interface language: \(language.rawValue)", "Appearance: \(theme.rawValue)"]
        if let managed {
            context += ["Selected game: \(managed.name)", "Launch method: \(managed.effectiveLaunchMethod.rawValue)"]
        } else if let external {
            context += ["Selected game: \(external.name)", "Launch method: CrossOver", "External environment: \(external.bottleName)"]
        }
        if let bottle {
            context += ["Log environment: \(bottle.name)", "Environment status: \(bottle.status.rawValue)",
                        "Graphics backend: \(bottle.graphics?.backend.rawValue ?? "wineDefault")"]
            if let operation = operations[bottle.id] { context.append("Operation: \(L10n.text(operation))") }
        }
        if !engineVersion.isEmpty { context.append("Connected Wine: \(engineVersion)") }
        var log = "No Wine log is available for this context."
        if let bottle, let store, let handle = try? FileHandle(forReadingFrom: store.logURL(for: bottle)) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: size > 96000 ? size - 96000 : 0)) != nil,
               let data = try? handle.readToEnd() { log = String(decoding: data, as: UTF8.self) }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let title = CrashReporting.redact(error?.title ?? "Portico · \(section.title)")
        let description = String(decoding: CrashReporting.redact(error?.message ?? "").utf16.prefix(6000), as: UTF16.self)
        return CrashReport(title: title, description: description, appVersion: "\(version) (\(build))",
                           diagnostics: CrashReporting.reviewDiagnostics(context: context, log: log))
    }
}

struct CrashReportView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var report: CrashReport
    @State private var sending = false
    @State private var failure: String?
    @State private var receipt: String?
    @State private var attempted = false
    @State private var nativeAttached = false

    init(model: AppModel, report: CrashReport) {
        self.model = model
        _report = State(initialValue: report)
    }

    private func text(_ uk: String, _ en: String) -> String { CrashReportText.text(uk, en) }
    private var canSend: Bool {
        report.consent && !sending && !report.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !report.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && report.title.utf16.count <= 200 && report.description.utf16.count <= 6000
            && report.diagnostics.utf16.count <= CrashReporting.maximumDiagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(report.kind == .suggestion ? text("Пропозиція для Portico", "Suggest an idea") : text("Репорт у підтримку", "Report to support"), systemImage: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 24, weight: .semibold))
            if let receipt {
                VStack(alignment: .leading, spacing: 16) {
                    Label(text("Звіт отримано", "Report received"), systemImage: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(Palette.mint)
                    Text(text("Дякуємо. Збережіть номер звіту для звернення до підтримки.", "Thank you. Keep the report ID for follow-up with support."))
                        .foregroundStyle(Palette.muted)
                    Text(receipt).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("crash-report-receipt")
                    Button(text("Відкрити звернення на сайті ↗", "View report on the website ↗")) {
                        openURL(CrashReporting.boardURL(kind: report.kind, id: receipt))
                    }.buttonStyle(PorticoButtonStyle()).accessibilityIdentifier("feedback-open-receipt")
                }.padding(.vertical, 25)
                HStack { Spacer(); Button(text("Готово", "Done")) { dismiss() }.buttonStyle(PorticoButtonStyle(primary: true)) }
            } else {
                Text(text("Дані зібрано на цьому Mac. Перегляньте їх перед надсиланням на сайт Portico. «Скасувати» закриє форму без надсилання.", "The data was collected on this Mac. Review it before sending it to the Portico website. Cancel closes the form without uploading."))
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(text("Тип звернення", "Feedback type"), selection: $report.kind) {
                            Text(text("Збій", "Crash")).tag(FeedbackKind.crash)
                            Text(text("Пропозиція", "Suggestion")).tag(FeedbackKind.suggestion)
                        }.pickerStyle(.segmented).accessibilityIdentifier("feedback-kind")
                        HStack(spacing: 15) {
                            Label("Portico \(report.appVersion)", systemImage: "app")
                            Text(report.osVersion)
                            Text(report.architecture)
                        }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityElement(children: .combine).accessibilityIdentifier("crash-report-system-info")
                        TextField(text("Коротко про проблему", "A short title"), text: $report.title)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("crash-report-title")
                        Text(report.kind == .suggestion ? text("Що пропонуєте та як це допоможе?", "What do you suggest, and how would it help?") : text("Що ви робили та що сталося?", "What were you doing, and what happened?"))
                            .font(.system(size: 13, weight: .medium))
                        TextEditor(text: $report.description).frame(height: 65)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.separator))
                            .accessibilityIdentifier("crash-report-description")
                        if report.kind == .crash {
                        HStack {
                            Text(text("Зібрана діагностика — можна редагувати", "Collected diagnostics — editable"))
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button(text("Додати crash report", "Attach crash report")) { attachNativeCrash() }
                                .buttonStyle(.plain).foregroundStyle(Palette.mint).font(.system(size: 12))
                                .disabled(nativeAttached).accessibilityIdentifier("crash-report-attach-native")
                        }
                        TextEditor(text: $report.diagnostics).font(.system(size: 11, design: .monospaced)).frame(height: 155)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.separator))
                            .accessibilityIdentifier("crash-report-diagnostics")
                        }
                        if report.title.utf16.count > 200 || report.description.utf16.count > 6000 || report.diagnostics.utf16.count > CrashReporting.maximumDiagnostics {
                            Text(text("Скоротіть заголовок до 200 символів, опис до 6000, діагностику до 256 КБ.", "Limit the title to 200 characters, description to 6,000 and diagnostics to 256 Ki characters."))
                                .font(.caption).foregroundStyle(Palette.amber)
                        }
                        Text(text("Заголовок, опис, версія Portico, дата та статус з’являться на відкритій дошці. Логи й дані Mac бачить лише розробник. Пропозиції надсилаються без логів. Перевірте текст на особисті дані. Термін зберігання — до 30 днів.", "The title, description, Portico version, date and status will appear on the public board. Logs and Mac details are visible only to the developer. Suggestions send no logs. Check the text for personal data. Retention: up to 30 days."))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        Toggle(text("Я переглянув(-ла) дані й погоджуюся надіслати звернення та опублікувати його опис.", "I reviewed the data and agree to send the report and publish its description."), isOn: $report.consent)
                            .font(.system(size: 12)).accessibilityIdentifier("crash-report-consent")
                        if let failure {
                            Text(failure).font(.callout).foregroundStyle(Palette.amber).textSelection(.enabled)
                                .accessibilityIdentifier("crash-report-error")
                        }
                    }.padding(2)
                }.frame(maxHeight: 490)
                HStack(spacing: 12) {
                    Button(text("Скасувати", "Cancel")) { dismiss() }
                        .buttonStyle(PorticoButtonStyle()).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("crash-report-cancel")
                    Text("Portico Support · HTTPS").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button(text("Надіслати репорт", "Send report")) { send() }
                        .buttonStyle(PorticoButtonStyle(primary: true)).disabled(!canSend)
                        .accessibilityIdentifier("crash-report-send")
                }
            }
        }.padding(28).frame(width: 690).foregroundStyle(Palette.text).background(Palette.background)
            .disabled(sending).interactiveDismissDisabled(sending)
            .onChange(of: report.title) { _, _ in edited() }
            .onChange(of: report.description) { _, _ in edited() }
            .onChange(of: report.diagnostics) { _, _ in edited() }
            .onChange(of: report.kind) { _, kind in
                report.diagnostics = kind == .suggestion ? "" : model.makeCrashReport().diagnostics
                nativeAttached = false
                edited()
            }
    }

    private func edited() {
        report.consent = false
        if attempted {
            // Unchanged retries reuse an ID; edited payloads need their own receipt.
            report.clientReportId = UUID().uuidString.lowercased()
            attempted = false
        }
        failure = nil
    }

    private func attachNativeCrash() {
        if let native = CrashReporting.recentNativeCrash() {
            report.diagnostics += "\n\n--- Native Portico crash ---\n" + native
            nativeAttached = true
        } else {
            failure = text("Свіжого звіту Portico за останні 7 днів не знайдено.", "No Portico crash report was found from the last 7 days.")
        }
    }

    private func send() {
        guard canSend else { return }
        sending = true; failure = nil; attempted = true
        var submitted = report
        submitted.publicConsent = true
        Task { @MainActor in
            do { receipt = try await CrashReporting.send(submitted) }
            catch { failure = error.localizedDescription }
            sending = false
        }
    }
}
