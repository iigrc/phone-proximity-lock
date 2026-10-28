import AppKit
import IOBluetooth
import IOBluetoothUI
import Darwin

func canonicalAddress(_ value: String) -> String {
    value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").lowercased()
}

extension Monitor {
    func prepareApplicationData() -> Bool {
        if !previewMode {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.phoneproximity.lock")
                .filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                notice("Phone Lock is already running", "Quit the existing Phone Lock from its menu bar menu, then open this version again.")
                return false
            }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !previewMode && !FileManager.default.fileExists(atPath: configURL.path) {
                let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("phone-proximity-lock/config.json")
                if let data = try? Data(contentsOf: legacy), var previous = try? JSONDecoder().decode(Configuration.self, from: data) {
                    // The upgraded binary needs a fresh Accessibility/Keychain grant.
                    previous.autoUnlockEnabled = false
                    try JSONEncoder().encode(previous).write(to: configURL, options: .atomic)
                }
            }
            return true
        } catch {
            notice("Unable to save settings", error.localizedDescription)
            return false
        }
    }
    func pairedDevices() -> [IOBluetoothDevice] {
        var seen = Set<String>()
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { device in
                guard device.isPaired(), let address = device.addressString else { return false }
                return seen.insert(canonicalAddress(address)).inserted
            }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }
    func pairedDevice(address: String) -> IOBluetoothDevice? {
        guard !address.isEmpty else { return nil }
        return pairedDevices().first { canonicalAddress($0.addressString ?? "") == canonicalAddress(address) }
    }
    @objc func showSettings() {
        if settingsController == nil { settingsController = DeviceSettingsController(owner: self) }
        settingsController?.refreshDevices()
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func pairNewDevice() {
        guard !previewMode, !screenIsLocked() else { return }
        let pairing = IOBluetoothPairingController()
        pairing.setTitle("Pair a device for Phone Lock")
        pairing.setDescriptionText("Make your phone discoverable in its Bluetooth settings, select it, and confirm the matching code on both devices.")
        pairing.setPrompt("Pair")
        NSApp.activate(ignoringOtherApps: true)
        let result = pairing.runModal()
        settingsController?.refreshDevices()
        if result == kIOBluetoothUISuccess,
           let devices = pairing.getResults() as? [IOBluetoothDevice], let selected = devices.first,
           selected.isPaired() {
            selectDevice(selected)
        }
    }
    func selectDevice(_ selected: IOBluetoothDevice) {
        guard !screenIsLocked(), !unlockInProgress, selected.isPaired(), let address = selected.addressString else { return }
        let changed = configuration.chooseDevice(address: address, enableAutomation: !previewMode)
        connectionWorker.reset()
        if changed {
            if ownedConnection, let old = device, old.isConnected() { _ = old.closeConnection() }
            unlockGate.reset(); appLockPending = false
        }
        device = selected; ownedConnection = !selected.isConnected()
        lastAttempt = .distantPast; pending = false; seenNear = false
        awaySince = nil; latched = false; lastConnection = nil
        deviceInfo.title = selected.name ?? "Selected Bluetooth device"
        saveConfiguration()
        log("Selected device=\(selected.name ?? "unknown"); preview=\(previewMode); unlockEnabled=\(configuration.autoUnlockEnabled)")
        settingsController?.refreshStatus(); tick()
    }
    var loginAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.phoneproximity.lock.plist")
    }
    func startsAtLogin() -> Bool {
        guard !previewMode, let data = try? Data(contentsOf: loginAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return false }
        return args.contains(Bundle.main.bundleURL.path)
    }
    func setStartAtLogin(_ enabled: Bool) {
        guard !previewMode else { return }
        if enabled && Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent != "Applications" {
            notice("Move the app to Applications first", "Move Phone Proximity Lock.app to your Applications folder, quit this copy, and reopen it there before enabling Start at login.")
            return
        }
        do {
            let label = "local.phoneproximity.lock"
            let domain = "gui/\(getuid())"
            let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            stop.arguments = ["bootout", "\(domain)/\(label)"]
            stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
            try stop.run(); stop.waitUntilExit()
            if enabled {
                let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundleURL.path], "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
                try FileManager.default.createDirectory(at: loginAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: loginAgentURL, options: .atomic)
                let start = Process(); start.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                start.arguments = ["bootstrap", domain, loginAgentURL.path]
                start.standardOutput = FileHandle.nullDevice; start.standardError = FileHandle.nullDevice
                try start.run(); start.waitUntilExit()
                if start.terminationStatus != 0 { throw NSError(domain: "PhoneLock.Login", code: Int(start.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "macOS could not load the login item. You can add this app in System Settings → General → Login Items."]) }
            } else if FileManager.default.fileExists(atPath: loginAgentURL.path) {
                try FileManager.default.removeItem(at: loginAgentURL)
            }
            log("Start at login enabled=\(enabled)")
        } catch { notice("Login item", error.localizedDescription) }
    }
}

final class DeviceSettingsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    unowned let monitor: Monitor
    var devices: [IOBluetoothDevice] = []
    let table = NSTableView()
    let current = NSTextField(labelWithString: "No device selected")
    let connection = NSTextField(labelWithString: "")
    let automation = NSButton(checkboxWithTitle: "Lock automatically when the selected device disconnects", target: nil, action: nil)
    let unlocking = NSButton(checkboxWithTitle: "Unlock automatically when the selected device reconnects", target: nil, action: nil)
    let login = NSButton(checkboxWithTitle: "Start Phone Lock when I log in", target: nil, action: nil)
    let lockDelay = NSPopUpButton()
    let unlockDelay = NSPopUpButton()
    let use = NSButton(title: "Use selected device", target: nil, action: nil)
    let testButton = NSButton(title: "Test unlocking", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove saved password", target: nil, action: nil)
    var refreshTimer: Timer?

    init(owner: Monitor) {
        self.monitor = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 690), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = previewMode ? "Phone Lock — Setup Preview" : "Phone Lock — Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI(); window.center()
        refreshTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func label(_ text: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
        return button
    }
    func buildUI() {
        let view = NSView(); window!.contentView = view
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)])
        let title = label("Your device. Your Mac.", size: 24); title.font = .boldSystemFont(ofSize: 24)
        stack.addArrangedSubview(title)
        let intro = label(previewMode ? "Preview only: you can try the picker here. Locking, unlocking, pairing and login changes are disabled." : "Choose a paired Bluetooth device, or pair a new one. A phone that maintains its connection usually works best.", secondary: true)
        stack.addArrangedSubview(intro); intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table.headerView = NSTableHeaderView(); table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 30
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "Paired device"; name.width = 390; table.addTableColumn(name)
        let state = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state")); state.title = "Connection"; state.width = 180; table.addTableColumn(state)
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = true
        scroll.documentView = table; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let pair = button("Pair a new device…", #selector(pair)); pair.isEnabled = !previewMode
        use.target = self; use.action = #selector(useDevice); use.bezelStyle = .rounded
        let row = NSStackView(views: [pair, button("Refresh", #selector(refresh)), NSView(), use]); row.spacing = 8
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        current.font = .boldSystemFont(ofSize: 13); stack.addArrangedSubview(current)
        connection.textColor = .secondaryLabelColor; stack.addArrangedSubview(connection)
        let divider = NSBox(); divider.boxType = .separator; stack.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        automation.target = self; automation.action = #selector(toggleAutomation); stack.addArrangedSubview(automation)
        unlocking.target = self; unlocking.action = #selector(toggleUnlocking); stack.addArrangedSubview(unlocking)
        let unlockHelp = label("Unlocking is optional and off by default. Enabling it requires Accessibility access and your own Mac password in your login Keychain. Manual locks and first login after restart stay manual.", size: 12, secondary: true)
        stack.addArrangedSubview(unlockHelp); unlockHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for seconds in [5, 10, 20, 30, 60] { lockDelay.addItem(withTitle: "\(seconds) seconds"); lockDelay.lastItem?.tag = seconds }
        for (index, seconds) in [0.5, 1.0, 2.0, 4.0].enumerated() { unlockDelay.addItem(withTitle: "\(seconds) seconds"); unlockDelay.lastItem?.tag = index }
        lockDelay.target = self; lockDelay.action = #selector(changeTiming)
        unlockDelay.target = self; unlockDelay.action = #selector(changeTiming)
        let timing = NSStackView(views: [label("Lock after"), lockDelay, label("Unlock after"), unlockDelay]); timing.spacing = 8
        stack.addArrangedSubview(timing)
        login.target = self; login.action = #selector(toggleLogin); stack.addArrangedSubview(login)
        testButton.target = self; testButton.action = #selector(testUnlocking); testButton.bezelStyle = .rounded
        removeButton.target = self; removeButton.action = #selector(removePassword); removeButton.bezelStyle = .rounded
        let links = NSStackView(views: [testButton, removeButton]); links.spacing = 8
        stack.addArrangedSubview(links)
        let foot = label("Bluetooth range varies. Detection pauses when the Mac sleeps; this app does not keep your Mac awake.", size: 12, secondary: true)
        stack.addArrangedSubview(foot); foot.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshDevices()
    }
    func refreshDevices() {
        let selectedAddress = table.selectedRow >= 0 && table.selectedRow < devices.count ? devices[table.selectedRow].addressString : nil
        devices = monitor.pairedDevices(); table.reloadData()
        let target = selectedAddress ?? monitor.configuration.address
        if let index = devices.firstIndex(where: { canonicalAddress($0.addressString ?? "") == canonicalAddress(target) }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        refreshStatus()
    }
    func refreshStatus() {
        guard isWindowLoaded else { return }
        current.stringValue = "Selected device: \(monitor.device?.name ?? "None")"
        connection.stringValue = previewMode ? "Preview — automation is disabled" : (monitor.device == nil ? "Select a paired device to start." : (monitor.currentDeviceConnected() ? "Connected" : "Waiting for Bluetooth connection"))
        automation.state = monitor.configuration.enabled ? .on : .off
        unlocking.state = monitor.configuration.autoUnlockEnabled ? .on : .off
        let editable = !previewMode && monitor.device != nil
        automation.isEnabled = editable; unlocking.isEnabled = editable
        login.state = monitor.startsAtLogin() ? .on : .off; login.isEnabled = !previewMode
        lockDelay.selectItem(withTag: Int(monitor.configuration.awaySeconds))
        unlockDelay.selectItem(withTag: [0.5, 1.0, 2.0, 4.0].firstIndex(of: monitor.configuration.unlockStableSeconds) ?? 1)
        lockDelay.isEnabled = !previewMode; unlockDelay.isEnabled = !previewMode
        use.isEnabled = table.selectedRow >= 0 && table.selectedRow < devices.count
        testButton.isEnabled = editable && monitor.passwordReady && monitor.configuration.autoUnlockEnabled && monitor.currentDeviceConnected()
        removeButton.isEnabled = !previewMode && monitor.passwordReady
    }
    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = devices[row]
        let value = tableColumn?.identifier.rawValue == "name" ? (device.name ?? device.addressString ?? "Bluetooth device") : (device.isConnected() ? "Connected" : "Not connected")
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingTail
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshStatus() }
    @objc func refresh() { refreshDevices() }
    @objc func pair() { monitor.pairNewDevice(); refreshDevices() }
    @objc func useDevice() { guard table.selectedRow >= 0 && table.selectedRow < devices.count else { return }; monitor.selectDevice(devices[table.selectedRow]); refreshStatus() }
    @objc func toggleAutomation() { monitor.toggleEnabled(); refreshStatus() }
    @objc func toggleUnlocking() { monitor.toggleUnlock(); refreshStatus() }
    @objc func toggleLogin() { monitor.setStartAtLogin(login.state == .on); refreshStatus() }
    @objc func changeTiming() {
        guard !previewMode else { return }
        monitor.configuration.awaySeconds = Double(lockDelay.selectedTag())
        monitor.configuration.unlockStableSeconds = [0.5, 1.0, 2.0, 4.0][unlockDelay.selectedTag()]
        monitor.saveConfiguration()
    }
    @objc func testUnlocking() { if !previewMode { monitor.testUnlock() } }
    @objc func removePassword() { if !previewMode { monitor.forgetUnlockPassword(); refreshStatus() } }
}
