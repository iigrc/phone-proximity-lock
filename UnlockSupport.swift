import AppKit
import ApplicationServices
import Security
import OpenDirectory
import IOKit.pwr_mgt
import LocalAuthentication

struct UnlockGate {
    private(set) var ownsLock = false
    private(set) var attempted = false
    private var connectedSince: Date?
    mutating func appLocked() { ownsLock = true; attempted = false; connectedSince = nil }
    mutating func reset() { self = UnlockGate() }
    mutating func observe(connected: Bool, now: Date) {
        guard ownsLock else { return }
        if !connected { connectedSince = nil }
        else if connectedSince == nil { connectedSince = now }
    }
    func eligible(now: Date, stableSeconds: Double = 1) -> Bool {
        ownsLock && !attempted && connectedSince.map { now.timeIntervalSince($0) >= stableSeconds } == true
    }
    mutating func beginAttempt() { attempted = true }
}

enum PasswordStore {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.phoneproximity.lock.autounlock",
         kSecAttrAccount as String: NSUserName(),
         kSecAttrSynchronizable as String: false]
    }
    static func exists() -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }
    static func save(_ password: String) -> OSStatus {
        guard var bytes = password.data(using: .utf8) else { return errSecParam }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        var attributes = query
        attributes[kSecAttrLabel as String] = "Phone Lock — automatic Mac unlock"
        attributes[kSecValueData as String] = bytes
        let result = SecItemAdd(attributes as CFDictionary, nil)
        if result == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        }
        return result
    }
    static func fetch(interactionAllowed: Bool = false) -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactionAllowed {
            let context = LAContext(); context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        guard result == errSecSuccess else { log("Unlock password unavailable: Keychain status=\(result)"); return nil }
        return value as? Data
    }
    static func remove() -> OSStatus { SecItemDelete(query as CFDictionary) }
    static func verifyLoginPassword(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch { return false }
    }
}

func runUnlockGateTests() {
    let fresh = Configuration()
    precondition(fresh.address.isEmpty && !fresh.enabled && !fresh.autoUnlockEnabled, "Fresh installs must not inherit a device or password-based unlocking")
    precondition(canonicalAddress("00:11:22:AA:BB:CC") == canonicalAddress("00-11-22-aa-bb-cc"))
    var selection = Configuration()
    selection.address = "00:11:22:AA:BB:CC"; selection.autoUnlockEnabled = true
    precondition(!selection.chooseDevice(address: "00-11-22-aa-bb-cc", enableAutomation: true))
    precondition(selection.autoUnlockEnabled, "Selecting the same device preserves an explicit unlock choice")
    precondition(selection.chooseDevice(address: "00:11:22:AA:BB:DD", enableAutomation: true))
    precondition(!selection.autoUnlockEnabled, "A new device must require fresh unlock opt-in")
    let start = Date(timeIntervalSince1970: 1000)
    var gate = UnlockGate()
    gate.observe(connected: true, now: start)
    precondition(!gate.eligible(now: start.addingTimeInterval(60)), "Manual locks must never unlock")
    gate.appLocked()
    gate.observe(connected: false, now: start)
    precondition(!gate.eligible(now: start.addingTimeInterval(60)), "Disconnected phone cannot unlock")
    gate.observe(connected: true, now: start)
    precondition(!gate.eligible(now: start.addingTimeInterval(0.9)), "Wait for stable connection")
    precondition(gate.eligible(now: start.addingTimeInterval(1)), "Stable reconnect should unlock app-owned lock")
    precondition(!gate.eligible(now: start.addingTimeInterval(3.9), stableSeconds: 4), "Custom wait must be honored")
    precondition(gate.eligible(now: start.addingTimeInterval(4), stableSeconds: 4))
    gate.observe(connected: false, now: start.addingTimeInterval(5))
    gate.observe(connected: true, now: start.addingTimeInterval(6))
    precondition(!gate.eligible(now: start.addingTimeInterval(6.9)), "Flapping connection must restart stability delay")
    precondition(gate.eligible(now: start.addingTimeInterval(7)))
    gate.beginAttempt()
    precondition(!gate.eligible(now: start.addingTimeInterval(60)), "Only one credential submission per lock")
    gate.reset(); gate.observe(connected: true, now: start)
    precondition(!gate.eligible(now: start.addingTimeInterval(60)), "Manual unlock resets ownership")
    let legacy = Data("{\"enabled\":true,\"address\":\"00:11:22:33:44:55\",\"awaySeconds\":20}".utf8)
    precondition((try? JSONDecoder().decode(Configuration.self, from: legacy).autoUnlockEnabled) == false)
    precondition(!ConnectionRetryGate.shouldStart(connected: true, pending: false, lastAttempt: start, now: start.addingTimeInterval(3), interval: 3))
    precondition(!ConnectionRetryGate.shouldStart(connected: false, pending: true, lastAttempt: start, now: start.addingTimeInterval(9.9), interval: 3), "Wait for a live Bluetooth request")
    precondition(ConnectionRetryGate.shouldStart(connected: false, pending: true, lastAttempt: start, now: start.addingTimeInterval(10), interval: 3), "Recover when a Bluetooth callback never arrives")
    precondition(!ConnectionRetryGate.shouldStart(connected: false, pending: false, lastAttempt: start, now: start.addingTimeInterval(2.9), interval: 3))
    precondition(ConnectionRetryGate.shouldStart(connected: false, pending: false, lastAttempt: start, now: start.addingTimeInterval(3), interval: 3))
    print("Unlock timing, retry, and configuration checks passed; no Keychain or UI access")
}

enum UnlockResult { case unlocked, unavailable, notReady, failed }

final class UnlockEngine {
    private var assertion: IOPMAssertionID = 0
    private var readinessChecks = 0
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func trustedSecureField(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              ["com.apple.loginwindow", "com.apple.SecurityAgent"].contains(bundle) else { return false }
        return attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
            || attribute(element, kAXRoleAttribute) as? String == "AXSecureTextField"
    }
    private func secureLoginField() -> AXUIElement? {
        let deadline = Date().addingTimeInterval(1)
        let system = AXUIElementCreateSystemWide()
        if let value = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            let focused = unsafeBitCast(value, to: AXUIElement.self)
            if trustedSecureField(focused) { return focused }
        }
        for app in NSWorkspace.shared.runningApplications where ["com.apple.loginwindow", "com.apple.SecurityAgent"].contains(app.bundleIdentifier ?? "") {
            var pending = [AXUIElementCreateApplication(app.processIdentifier)]
            var visited = 0
            while let element = pending.popLast(), visited < 40, Date() < deadline {
                visited += 1
                if trustedSecureField(element), attribute(element, kAXEnabledAttribute) as? Bool != false { return element }
                if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children) }
            }
        }
        return nil
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
    private func focusIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let value = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return trustedSecureField(unsafeBitCast(value, to: AXUIElement.self))
    }
    func run(canProceed: @escaping () -> Bool, isLocked: @escaping () -> Bool, completion: @escaping (UnlockResult) -> Void) {
        guard AXIsProcessTrusted() else { completion(.unavailable); return }
        readinessChecks = 0
        _ = IOPMAssertionDeclareUserActivity("Phone Lock reconnect" as CFString, kIOPMUserActiveLocal, &assertion)
        // Space reveals the password field without submitting a login attempt.
        // Select-all below clears it before any credential is entered.
        key(0x31)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.checkReady(canProceed: canProceed, isLocked: isLocked, completion: completion)
        }
    }
    private func checkReady(canProceed: @escaping () -> Bool, isLocked: @escaping () -> Bool, completion: @escaping (UnlockResult) -> Void) {
        guard canProceed() else { completion(isLocked() ? .notReady : .unlocked); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let field = self.secureLoginField()
            DispatchQueue.main.async {
                guard canProceed() else { completion(isLocked() ? .notReady : .unlocked); return }
                if let field {
                    self.submit(field: field, canProceed: canProceed, isLocked: isLocked, completion: completion)
                    return
                }
                self.readinessChecks += 1
                guard self.readinessChecks < 5 else {
                    log("Unlock skipped: secure login field unavailable after bounded checks")
                    completion(.notReady); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.checkReady(canProceed: canProceed, isLocked: isLocked, completion: completion)
                }
            }
        }
    }
    private func submit(field: AXUIElement, canProceed: @escaping () -> Bool, isLocked: @escaping () -> Bool, completion: @escaping (UnlockResult) -> Void) {
        guard canProceed(), trustedSecureField(field), var bytes = PasswordStore.fetch() else { completion(.unavailable); return }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard var password = String(data: bytes, encoding: .utf8), !password.isEmpty else { completion(.unavailable); return }
        defer { password = "" }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard canProceed() else { completion(.notReady); return }
        // loginwindow may acknowledge AX value writes without updating its authentication
        // buffer. Use keyboard events, with a secure-focus check before every character.
        do {
            guard focusIsSecure(), canProceed() else { log("Unlock skipped: secure focus unavailable"); completion(.notReady); return }
            key(0x00, flags: .maskCommand)
            key(0x33)
            let source = CGEventSource(stateID: .hidSystemState)
            for scalar in password.unicodeScalars {
                guard canProceed(), focusIsSecure() else { log("Unlock stopped: secure focus changed"); completion(.notReady); return }
                var units = Array(String(scalar).utf16)
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                units.withUnsafeBufferPointer { buffer in
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                event?.flags = []; event?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
                for index in units.indices { units[index] = 0 }
            }
        }
        guard canProceed(), focusIsSecure() else { completion(.notReady); return }
        log("UNLOCK_SUBMITTED through keyboard events to secure login field; postAccess=\(CGPreflightPostEventAccess())")
        key(0x24)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            completion(isLocked() ? .failed : .unlocked)
        }
    }
}

extension Monitor {
    @objc func authorizeSavedUnlock() {
        guard !previewMode, device != nil else { return }
        guard !screenIsLocked(), AXIsProcessTrusted() else {
            notice("Permission required", "Enable Phone Proximity Lock in Privacy & Security → Device Control and Data Access, then use Set up automatic unlocking again.")
            return
        }
        setupState = "reauthorizing_keychain"
        guard var password = PasswordStore.fetch(interactionAllowed: true) else {
            setupState = "keychain_authorization_needed"
            notice("Keychain access unavailable", "Use Set or change saved unlock password from the Phone Lock menu to try again.")
            return
        }
        password.resetBytes(in: 0..<password.count)
        passwordReady = true; configuration.autoUnlockEnabled = true; saveConfiguration()
        log("Updated build authorized to use saved unlock password")
        testUnlock()
    }
    func saveConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) {
            try? data.write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }
    func notice(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc func configureUnlock() {
        guard !previewMode, device != nil else { showSettings(); return }
        guard !screenIsLocked() else { return }
        setupState = "accessibility"
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            let alert = NSAlert()
            alert.messageText = "Allow Phone Proximity Lock to enter your password"
            alert.informativeText = "In System Settings → Privacy & Security → Accessibility, enable Phone Proximity Lock, then choose Continue here. The app will only enter the saved password into a verified system login field after one of its own locks."
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, AXIsProcessTrusted() else {
                setupState = "accessibility_not_granted"; log("Unlock setup awaiting Accessibility permission"); return
            }
        }
        setupState = "awaiting_password"
        log("Unlock setup: waiting for direct entry in secure local password field")
        let alert = NSAlert()
        alert.messageText = "Set up unlock on phone reconnect"
        alert.informativeText = "Enter the Mac login password for \(NSUserName()). It will be checked locally and saved in your login Keychain. Saving will test the feature by locking this Mac once and unlocking it again while the phone is connected. Manual locks and first login after restart stay manual."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.placeholderString = "Mac login password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save & test"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { field.stringValue = ""; setupState = "cancelled"; return }
        var password = field.stringValue
        field.stringValue = ""
        defer { password = "" }
        guard !password.isEmpty, PasswordStore.verifyLoginPassword(password) else {
            setupState = "password_not_verified"
            notice("Password not saved", "The Mac login password could not be verified. Try Set up automatic unlocking again from the Phone Lock menu.")
            return
        }
        let result = PasswordStore.save(password)
        guard result == errSecSuccess else {
            setupState = "keychain_error"
            notice("Password not saved", "Keychain returned error \(result). Automatic unlocking remains off.")
            return
        }
        passwordReady = true; configuration.autoUnlockEnabled = true; saveConfiguration()
        setupState = "configured"
        log("Unlock password verified and saved in login Keychain; automatic unlock enabled")
        guard currentDeviceConnected(), configuration.enabled else {
            notice("Automatic unlocking enabled", "The phone must be connected and phone automation enabled before running a test. Use Test automatic unlocking from the menu when ready.")
            return
        }
        testUnlock()
    }
    @objc func toggleUnlock() {
        guard !previewMode, device != nil else { showSettings(); return }
        if configuration.autoUnlockEnabled {
            configuration.autoUnlockEnabled = false; saveConfiguration(); log("Automatic unlocking paused")
        } else if passwordReady && AXIsProcessTrusted() {
            configuration.autoUnlockEnabled = true; saveConfiguration(); log("Automatic unlocking resumed")
        } else { configureUnlock() }
    }
    @objc func forgetUnlockPassword() {
        guard !previewMode else { return }
        configuration.autoUnlockEnabled = false; saveConfiguration()
        let result = PasswordStore.remove(); passwordReady = false
        log("Stored unlock password removal status=\(result)")
    }
    @objc func testUnlock() {
        guard !previewMode, configuration.autoUnlockEnabled, configuration.enabled, passwordReady, currentDeviceConnected(), !screenIsLocked(), let lockFunction else { return }
        log("UNLOCK_TEST_STARTED: controlled app-owned lock while phone connected")
        appLockPending = true
        lockFunction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.screenIsLocked() {
                if !self.unlockGate.ownsLock { self.unlockGate.appLocked() }
                self.appLockPending = false
                log("UNLOCK_TEST_LOCK_CONFIRMED")
            } else { self.appLockPending = false; log("UNLOCK_TEST_ERROR: lock not confirmed") }
        }
    }
    func considerUnlock(connected: Bool, locked: Bool, now: Date) {
        if !locked && !appLockPending { unlockGate.reset() }
        unlockGate.observe(connected: connected, now: now)
        guard locked, configuration.enabled, configuration.autoUnlockEnabled, passwordReady,
              unlockGate.eligible(now: now, stableSeconds: configuration.unlockStableSeconds), !unlockInProgress else { return }
        unlockGate.beginAttempt(); unlockInProgress = true
        log("UNLOCK_REQUESTED: app-owned lock and stable phone reconnection")
        unlockEngine.run(canProceed: { [weak self] in
            guard let self else { return false }
            return self.configuration.enabled && self.configuration.autoUnlockEnabled && self.unlockGate.ownsLock
                && self.currentDeviceConnected() && self.safeUnlockSession()
        }, isLocked: { [weak self] in self?.screenIsLocked() ?? true }) { [weak self] result in
            guard let self else { return }
            self.unlockInProgress = false
            switch result {
            case .unlocked: log("UNLOCK_CONFIRMED"); self.unlockGate.reset(); self.setupState = "unlock_verified"
            case .failed:
                log("UNLOCK_FAILED: automatic unlocking paused to avoid repeated password attempts")
                self.configuration.autoUnlockEnabled = false; self.saveConfiguration(); self.setupState = "unlock_failed"
            case .unavailable: log("Unlock unavailable: check Accessibility and Keychain access"); self.setupState = "unlock_unavailable"
            case .notReady: log("Unlock skipped: secure login field not ready; manual unlock required"); self.setupState = "unlock_not_ready"
            }
        }
    }
}
