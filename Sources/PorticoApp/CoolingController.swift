import AppKit
import Foundation
import PorticoCore

@MainActor
final class CoolingController: ObservableObject {
    enum State { case off, authorizing, starting, active, stopping }
    @Published private(set) var state: State = .off
    @Published private(set) var snapshot: CoolingSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var diagnostic = ""
    @Published private(set) var isRestoring = false
    private var transientReadError: String?
    private var session: URL?
    private var process: Process?
    private var timer: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var requestedStop = false

    var helperURL: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("PorticoCoolingHelper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }
    var canStart: Bool {
        !DistributionPolicy.isAppStore && state == .off && !isRestoring && snapshot?.isSystemAutomatic == true && helperURL != nil
    }

    init() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
    }
    deinit {
        timer?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let session { try? FileManager.default.removeItem(at: session.appendingPathComponent("lease")) }
    }
    func refresh() {
        do {
            snapshot = try CoolingSnapshot.read()
            if error == transientReadError { error = nil }
            transientReadError = nil
        }
        catch {
            snapshot = nil
            self.error = error.localizedDescription
            if state == .active { stop() }
            else { transientReadError = error.localizedDescription }
        }
    }
    func start() {
        guard state == .off else { return }
        error = nil; diagnostic = ""
        refresh()
        guard let snapshot else { return }
        guard snapshot.isSystemAutomatic else { error = CoolingError.externalControl.localizedDescription; return }
        guard let helper = helperURL else { error = CoolingError.helperMissing.localizedDescription; return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("portico-cooling-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            for (name, content) in [("lease", "active\n"), ("status", "authorizing\n")] {
                guard FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path,
                    contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
                    throw CoolingError.helperFailed
                }
            }
            session = folder
            requestedStop = false
            state = .authorizing
            let command = [helper.path, "--run", folder.appendingPathComponent("lease").path,
                String(getuid()), String(ProcessInfo.processInfo.processIdentifier),
                folder.appendingPathComponent("status").path].map(Self.shellQuote).joined(separator: " ")
            // Quoting is applied separately for POSIX shell arguments and AppleScript strings.
            let script = "do shell script " + Self.appleScriptQuote(command) + " with administrator privileges"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            task.standardError = errors
            task.terminationHandler = { [weak self] finished in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let details = String(decoding: data.suffix(4000), as: UTF8.self)
                Task { @MainActor in
                    self?.diagnostic = details.trimmingCharacters(in: .whitespacesAndNewlines)
                    await self?.finished(exitCode: finished.terminationStatus, folder: folder)
                }
            }
            process = task
            try task.run()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch {
            self.error = error.localizedDescription
            state = .off; process = nil; session = nil
            try? FileManager.default.removeItem(at: folder)
        }
    }
    func stop() {
        guard state != .off, let session else { return }
        requestedStop = true
        state = .stopping
        // The helper and independent recovery process both observe revocation.
        try? FileManager.default.removeItem(at: session.appendingPathComponent("lease"))
        // Keep the status poll alive until recovery confirms automatic control.
    }
    private func tick() {
        guard let session else { return }
        if state == .authorizing || state == .starting || state == .active {
            do {
                try FileManager.default.setAttributes([.modificationDate: Date()],
                    ofItemAtPath: session.appendingPathComponent("lease").path)
            } catch { self.error = error.localizedDescription; stop() }
        }
        if let status = try? String(contentsOf: session.appendingPathComponent("status"), encoding: .utf8) {
            if status == "starting\n", !requestedStop { state = .starting }
            if status == "active\n", !requestedStop { state = .active }
            if status == "stopping\n" { state = .stopping }
            if status == "restore-failed\n" { error = CoolingError.restoreFailed.localizedDescription }
        }
        refresh()
    }
    private func finished(exitCode: Int32, folder: URL) async {
        guard session == folder else { return }
        timer?.cancel(); timer = nil
        var status = try? String(contentsOf: folder.appendingPathComponent("status"), encoding: .utf8)
        if status == "active\n" || status == "stopping\n" {
            state = .stopping
            // The independent recovery child may outlive the shell after a worker crash.
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(200))
                status = try? String(contentsOf: folder.appendingPathComponent("status"), encoding: .utf8)
                if status == "restored\n" || status == "restore-failed\n" { break }
            }
            if status != "restored\n" { status = "restore-failed\n" }
        }
        if status == "restore-failed\n" {
            error = CoolingError.restoreFailed.localizedDescription
        } else if status != "restored\n", exitCode != 0 {
            error = CoolingError.helperFailed.localizedDescription
        } else if !requestedStop {
            error = CoolingError.helperFailed.localizedDescription
        }
        state = .off; process = nil; session = nil
        try? FileManager.default.removeItem(at: folder)
        refresh()
    }
    func restoreAutomatic() {
        guard state == .off, !isRestoring, let helper = helperURL else { return }
        isRestoring = true; error = nil; diagnostic = ""
        let task = Process(), errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let command = Self.shellQuote(helper.path) + " --restore"
        task.arguments = ["-e", "do shell script " + Self.appleScriptQuote(command) + " with administrator privileges"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = errors
        task.terminationHandler = { [weak self] finished in
            let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().suffix(4000), as: UTF8.self)
            Task { @MainActor in
                self?.isRestoring = false
                if finished.terminationStatus != 0 {
                    self?.error = CoolingError.restoreFailed.localizedDescription
                    self?.diagnostic = details.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self?.refresh()
            }
        }
        do { try task.run() }
        catch { isRestoring = false; self.error = error.localizedDescription }
    }
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
