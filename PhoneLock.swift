import AppKit
import IOBluetooth
import CoreGraphics
import Darwin

let previewMode = CommandLine.arguments.contains("--preview-setup")
let root = previewMode
    ? FileManager.default.temporaryDirectory.appendingPathComponent("PhoneLock-Preview-\(ProcessInfo.processInfo.processIdentifier)")
    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Phone Proximity Lock")
let configURL = root.appendingPathComponent("config.json")
let statusURL = root.appendingPathComponent("status.json")
let logURL = root.appendingPathComponent("monitor.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let bytes = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: logURL.path) { try? Data().write(to: logURL) }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        let length = handle.seekToEndOfFile()
        if length > 1_000_000 {
            try? handle.close()
            let tail = (try? Data(contentsOf: logURL).suffix(200_000)) ?? Data()
            try? Data(tail).write(to: logURL, options: .atomic)
            if let newHandle = try? FileHandle(forWritingTo: logURL) {
                newHandle.seekToEndOfFile(); newHandle.write(bytes); try? newHandle.close()
            }
        } else { handle.write(bytes); try? handle.close() }
    }
}

struct Configuration: Codable {
    var enabled = false
    var address = ""
    var awaySeconds: Double = 20
    var autoUnlockEnabled = false
    var unlockStableSeconds: Double = 1
    var reconnectRetrySeconds: Double = 3
    enum CodingKeys: String, CodingKey { case enabled, address, awaySeconds, autoUnlockEnabled, unlockStableSeconds, reconnectRetrySeconds }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        address = try values.decodeIfPresent(String.self, forKey: .address) ?? ""
        awaySeconds = try values.decodeIfPresent(Double.self, forKey: .awaySeconds) ?? 20
        autoUnlockEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoUnlockEnabled) ?? false
        unlockStableSeconds = try values.decodeIfPresent(Double.self, forKey: .unlockStableSeconds) ?? 1
        reconnectRetrySeconds = try values.decodeIfPresent(Double.self, forKey: .reconnectRetrySeconds) ?? 3
    }
    @discardableResult mutating func chooseDevice(address newAddress: String, enableAutomation: Bool) -> Bool {
        let changed = canonicalAddress(address) != canonicalAddress(newAddress)
        if changed || !enableAutomation { autoUnlockEnabled = false }
        address = newAddress; enabled = enableAutomation
        return changed
    }
}

enum ConnectionRetryGate {
    static func shouldStart(connected: Bool, pending: Bool, lastAttempt: Date, now: Date, interval: Double) -> Bool {
        let elapsed = now.timeIntervalSince(lastAttempt)
        return !connected && elapsed >= interval && (!pending || elapsed >= max(10, interval))
    }
}

final class Monitor: NSObject, NSApplicationDelegate {
    var configuration = Configuration()
    var item: NSStatusItem!
    var info = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    var toggle = NSMenuItem(title: "Enable automatic locking", action: #selector(toggleEnabled), keyEquivalent: "")
    var device: IOBluetoothDevice?
    var deviceInfo: NSMenuItem!
    var settingsController: DeviceSettingsController?
    var timer: Timer?
    var lastAttempt = Date.distantPast
    var pending = false
    var seenNear = false
    var awaySince: Date?
    var latched = false
    var lastState = ""
    var tickCount = 0
    var lastStatusWrite = Date.distantPast
    var lastStatusLog = Date.distantPast
    var lastConnection: Bool?
    var ownedConnection = false
    var lockFunction: (@convention(c) () -> Void)?
    var library: UnsafeMutableRawPointer?
    var lockObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?
    var singletonFD: Int32 = -1
    var unlockGate = UnlockGate()
    var unlockEngine = UnlockEngine()
    var unlockInProgress = false
    var appLockPending = false
    var passwordReady = false
    var setupState = "idle"
    var unlockToggle: NSMenuItem!
    var unlockObserver: NSObjectProtocol?
    let connectionWorker = BluetoothConnectionWorker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard prepareApplicationData() else { NSApp.terminate(nil); return }
        singletonFD = open(root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard singletonFD >= 0, flock(singletonFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        readConfiguration()
        device = pairedDevice(address: configuration.address)
        connectionWorker.onChange = { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
        if device == nil { configuration.enabled = false; configuration.autoUnlockEnabled = false }
        if previewMode { configuration.enabled = false; configuration.autoUnlockEnabled = false }
        passwordReady = previewMode ? false : PasswordStore.exists()
        ownedConnection = device.map { !$0.isConnected() } ?? false
        library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY | RTLD_LOCAL)
        if let library, let symbol = dlsym(library, "SACLockScreenImmediate") {
            lockFunction = unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = previewMode ? "Phone Lock Preview" : "Phone Lock"
        let menu = NSMenu()
        info.isEnabled = false; menu.addItem(info)
        deviceInfo = NSMenuItem(title: device?.name ?? "No device selected", action: nil, keyEquivalent: "")
        deviceInfo.isEnabled = false; menu.addItem(deviceInfo)
        let preferences = NSMenuItem(title: "Settings & devices…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self; menu.addItem(preferences)
        let pair = NSMenuItem(title: "Pair a new device…", action: #selector(pairNewDevice), keyEquivalent: "")
        pair.target = self; menu.addItem(pair)
        menu.addItem(.separator())
        toggle.target = self; menu.addItem(toggle)
        unlockToggle = NSMenuItem(title: "Set up automatic unlocking…", action: #selector(toggleUnlock), keyEquivalent: "")
        unlockToggle.target = self; menu.addItem(unlockToggle)
        let updatePassword = NSMenuItem(title: "Set or change saved unlock password…", action: #selector(configureUnlock), keyEquivalent: "")
        updatePassword.target = self; menu.addItem(updatePassword)
        let test = NSMenuItem(title: "Test automatic unlocking", action: #selector(testUnlock), keyEquivalent: "")
        test.target = self; menu.addItem(test)
        let forget = NSMenuItem(title: "Disable unlocking and remove saved password", action: #selector(forgetUnlockPassword), keyEquivalent: "")
        forget.target = self; menu.addItem(forget)
        let logs = NSMenuItem(title: "Open activity log…", action: #selector(openLog), keyEquivalent: "")
        logs.target = self; menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Phone Lock", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.seenNear = false; self.awaySince = nil; self.latched = false; self.pending = false
            self.lastAttempt = .distantPast
            log("Wake: waiting to detect phone nearby before arming")
            DispatchQueue.main.async { self.tick() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.appLockPending { self.unlockGate.appLocked(); self.appLockPending = false }
            else { self.unlockGate.reset() }
            log("LOCK_CONFIRMED by macOS notification; appOwned=\(self.unlockGate.ownsLock)")
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.unlockGate.reset(); log("Session unlocked")
        }
        log("Started device=\(device?.name ?? "none") enabled=\(configuration.enabled) lockAPI=\(lockFunction != nil)")
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
        if device == nil || previewMode || CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showSettings() }
        }
        if CommandLine.arguments.contains("--setup-unlock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.configureUnlock() }
        }
        if CommandLine.arguments.contains("--authorize-unlock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.authorizeSavedUnlock() }
        }
    }

    func readConfiguration() {
        if let data = try? Data(contentsOf: configURL), let value = try? JSONDecoder().decode(Configuration.self, from: data),
           value.awaySeconds >= 5, value.awaySeconds <= 300,
           value.unlockStableSeconds >= 0.25, value.unlockStableSeconds <= 10,
           value.reconnectRetrySeconds >= 1, value.reconnectRetrySeconds <= 30 {
            if configuration.enabled != value.enabled {
                awaySince = nil; latched = false
                log("Automatic locking enabled=\(value.enabled)")
            }
            configuration = value
        }
    }

    func tick() {
        readConfiguration()
        settingsController?.refreshStatus()
        guard !previewMode, let device else {
            info.title = previewMode ? "Preview — automation disabled" : "Choose a Bluetooth device in Settings"
            toggle.isEnabled = false; unlockToggle.isEnabled = false
            return
        }
        toggle.isEnabled = lockFunction != nil; unlockToggle.isEnabled = true
        deviceInfo.title = device.name ?? "Selected Bluetooth device"
        let now = Date()
        if configuration.enabled { connectionWorker.checkTimeout(now: now) }
        else if connectionWorker.isRunning { connectionWorker.reset() }
        let connected = currentDeviceConnected()
        pending = connectionWorker.connecting
        if lastConnection != connected { log("Connection changed connected=\(connected)"); lastConnection = connected }
        if configuration.enabled && !connectionWorker.isRunning && now.timeIntervalSince(lastAttempt) >= configuration.reconnectRetrySeconds {
            lastAttempt = now
            connectionWorker.start(address: configuration.address)
            pending = connectionWorker.connecting
        }
        let nearby = connected
        if nearby {
            if !seenNear { log("Phone nearby: presence tracking armed") }
            seenNear = true; awaySince = nil; latched = false
        }
        let away = !connected
        if away && seenNear {
            if awaySince == nil { awaySince = now; log("Phone disconnected: beginning \(configuration.awaySeconds)s delay") }
        } else if !away {
            if awaySince != nil { log("Phone reconnected: cancelled lock countdown") }
            awaySince = nil
        }
        let elapsed = awaySince.map { now.timeIntervalSince($0) } ?? 0
        let isLocked = screenIsLocked()
        if away && seenNear && elapsed >= configuration.awaySeconds && !latched && !isLocked {
            if configuration.enabled, let lockFunction {
                log("LOCK_REQUESTED: phone away for \(Int(elapsed))s")
                appLockPending = true
                lockFunction()
                latched = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    if self.screenIsLocked() {
                        if self.appLockPending { self.unlockGate.appLocked(); self.appLockPending = false }
                        log("LOCK_CONFIRMED by session state")
                    } else { self.appLockPending = false; log("ERROR: lock not confirmed; retrying while phone remains away"); self.latched = false }
                }
            } else {
                log(configuration.enabled ? "ERROR: lock API unavailable" : "WOULD_LOCK: test mode, phone away for \(Int(elapsed))s")
                latched = true
            }
        }
        let mode = configuration.enabled ? "Active" : "Paused"
        let state: String
        if lockFunction == nil { state = "Lock API unavailable" }
        else if !seenNear { state = "Waiting for phone connection" }
        else if latched && away { state = isLocked ? "Phone disconnected — locked" : "Phone disconnected" }
        else if away { state = "Phone disconnected — \(max(0, Int(configuration.awaySeconds - elapsed)))s" }
        else { state = "Phone connected" }
        info.title = "\(mode): \(state)"
        considerUnlock(connected: connected, locked: isLocked, now: now)
        toggle.title = configuration.enabled ? "Pause phone automation" : "Enable phone automation"
        unlockToggle.title = configuration.autoUnlockEnabled ? "Pause automatic unlocking" : (passwordReady ? "Resume automatic unlocking" : "Set up automatic unlocking…")
        toggle.isEnabled = lockFunction != nil
        let status: [String: Any] = ["time": ISO8601DateFormatter().string(from: now), "enabled": configuration.enabled,
            "connected": connected, "seenNear": seenNear, "awaySeconds": Int(elapsed),
            "state": state, "screenLocked": isLocked, "lockAPIAvailable": lockFunction != nil,
            "autoUnlockEnabled": configuration.autoUnlockEnabled, "unlockInProgress": unlockInProgress,
            "appOwnedLock": unlockGate.ownsLock, "setupState": setupState, "passwordConfigured": passwordReady,
            "unlockStableSeconds": configuration.unlockStableSeconds, "reconnectRetrySeconds": configuration.reconnectRetrySeconds]
        if (state != lastState || now.timeIntervalSince(lastStatusWrite) >= 2),
           let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: statusURL, options: .atomic)
            lastStatusWrite = now
        }
        tickCount += 1
        if state != lastState || now.timeIntervalSince(lastStatusLog) >= 30 {
            log("Status: \(mode), \(state), connected=\(connected)"); lastState = state
            lastStatusLog = now
        }
    }

    func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    func currentDeviceConnected() -> Bool {
        connectionWorker.reportedConnected ?? (device?.isConnected() ?? false)
    }
    func safeUnlockSession() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
            && session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
            && (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid()
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        pending = false; log("Connection result=\(status) connected=\(device.isConnected())")
        DispatchQueue.main.async { self.tick() }
    }
    @objc func toggleEnabled() {
        guard !previewMode, device != nil else { showSettings(); return }
        configuration.enabled.toggle()
        if let data = try? JSONEncoder().encode(configuration) { try? data.write(to: configURL, options: .atomic) }
        awaySince = nil; latched = false
        log("Menu: automatic locking enabled=\(configuration.enabled)"); tick()
    }
    @objc func openConfiguration() { NSWorkspace.shared.open(configURL) }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        connectionWorker.stop()
        if ownedConnection, let device, device.isConnected() { _ = device.closeConnection() }
        log("Monitor stopped")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
}

@main struct PhoneLockMain {
static func main() {
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--bluetooth-worker" {
    runBluetoothWorker(address: CommandLine.arguments[2])
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--worker-test" {
    runBluetoothWorkerIntegrationTest(address: CommandLine.arguments[2])
}
if CommandLine.arguments.contains("--self-test") { runUnlockGateTests(); return }
if CommandLine.arguments.contains("--lock-test") {
    guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY | RTLD_LOCAL),
          let symbol = dlsym(library, "SACLockScreenImmediate") else { log("LOCK_TEST_ERROR: lock API unavailable"); exit(1) }
    let lock = unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
    log("LOCK_TEST_REQUESTED")
    lock()
    Thread.sleep(forTimeInterval: 3)
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    log("LOCK_TEST_CONFIRMED=\(locked)")
    exit(locked ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let monitor = Monitor()
app.delegate = monitor
app.run()
}
}
