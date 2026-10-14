import Foundation
import Darwin
import PorticoCore
import CoolingSMC

// No arbitrary commands, SMC keys or paths to write are accepted by this helper.
// The sole writable hardware operation is the fixed Portico temperature profile.
private var stopping: sig_atomic_t = 0
private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

if CommandLine.arguments == [CommandLine.arguments[0], "--probe"] {
    do {
        let data = try JSONEncoder().encode(CoolingSnapshot.read())
        FileHandle.standardOutput.write(data)
        exit(0)
    } catch { fail(error.localizedDescription) }
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--restore" {
    guard !DistributionPolicy.isAppStore, geteuid() == 0 else { fail("Administrator permission is required") }
    let lockFD = open("/var/run/app.portico.cooling.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fail("A cooling session is still running") }
    let smc = pfc_open()
    guard smc != 0 else { fail("SMC unavailable") }
    let restored = pfc_restore(smc) != 0
    pfc_close(smc); close(lockFD)
    if !restored { fail("PORTICO_COOLING_RESTORE_FAILED") }
    exit(0)
}

guard !DistributionPolicy.isAppStore, geteuid() == 0,
      CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--run",
      let uid = UInt32(CommandLine.arguments[3]), uid > 0,
      let parent = Int32(CommandLine.arguments[4]), parent > 1 else {
    fail("Usage: PorticoCoolingHelper --probe | --run LEASE UID PARENT_PID STATUS")
}
let lease = CommandLine.arguments[2]
guard pfc_lease_valid(lease, uid, parent) != 0 else { fail("Invalid or expired cooling session") }
let lock = open("/var/run/app.portico.cooling.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fail("A cooling session is already running") }
let connection = pfc_open()
guard connection != 0 else { fail("SMC unavailable") }
// Validate before arming restoration; never reset an existing third-party profile.
guard pfc_is_automatic(connection) != 0 else { fail("External fan control is active") }
do { _ = try CoolingSnapshot.read() } catch { fail(error.localizedDescription) }
signal(SIGTERM) { _ in stopping = 1 }
signal(SIGINT) { _ in stopping = 1 }
signal(SIGHUP) { _ in stopping = 1 }
let statusFD = open(CommandLine.arguments[5], O_RDWR | O_NOFOLLOW | O_NONBLOCK)
var statusInfo = stat()
guard statusFD >= 0, fstat(statusFD, &statusInfo) == 0,
      (statusInfo.st_mode & S_IFMT) == S_IFREG, statusInfo.st_uid == uid,
      (statusInfo.st_mode & 0o777) == 0o600, statusInfo.st_nlink == 1 else {
    fail("Invalid status channel")
}
func report(_ text: String) {
    let data = Data((text + "\n").utf8)
    _ = ftruncate(statusFD, 0)
    data.withUnsafeBytes { bytes in _ = pwrite(statusFD, bytes.baseAddress, bytes.count, 0) }
}
report("starting")
let recovery = pfc_guard_start(lease, uid, parent, statusFD)
guard recovery >= 0 else { fail("Could not start cooling recovery process") }
var failure: String?
if pfc_begin_manual(connection) == 0 {
    failure = "Could not acquire fan control"
} else {
    var lastTargets: [Int: Double] = [:]
    let sessionStart = Date()
    while stopping == 0, pfc_lease_valid(lease, uid, parent) != 0,
          Date().timeIntervalSince(sessionStart) < 12 * 60 * 60 {
        do {
            let snapshot = try CoolingSnapshot.read()
            let state = ProcessInfo.processInfo.thermalState
            let emergency = state == .serious || state == .critical
            for fan in snapshot.fans {
                guard let target = CoolingPolicy.targetRPM(
                    temperature: max(snapshot.cpuTemperature, snapshot.gpuTemperature),
                    minimum: fan.minimumRPM, maximum: fan.maximumRPM,
                    previous: lastTargets[fan.id], thermalEmergency: emergency),
                    pfc_set_speed(connection, Int32(fan.id), target) != 0 else {
                        throw PorticoError.invalidInput("Could not set fan \(fan.id + 1) speed from the temperature profile")
                    }
                lastTargets[fan.id] = target
            }
            report("active")
        } catch { failure = error.localizedDescription; break }
        sleep(1)
    }
}
report("stopping")
pfc_close(connection)
// The recovery process owns restoration and checks the firmware's result.
let restored = pfc_guard_finish(recovery) != 0
close(lock)
if !restored { fail("PORTICO_COOLING_RESTORE_FAILED") }
if let failure { fail(failure) }
