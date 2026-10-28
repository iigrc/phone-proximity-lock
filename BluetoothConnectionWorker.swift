import Foundation
import IOBluetooth
import Darwin

struct BluetoothWorkerPacket: Codable {
    let connected: Bool
    let authenticated: Bool
    let status: Int32
}

func runBluetoothWorker(address: String) -> Never {
    let parent = getppid()
    func send(connected: Bool, authenticated: Bool, status: Int32) {
        guard var data = try? JSONEncoder().encode(BluetoothWorkerPacket(connected: connected, authenticated: authenticated, status: status)) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
    guard !address.isEmpty, let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
        send(connected: false, authenticated: false, status: -1); exit(1)
    }
    send(connected: false, authenticated: false, status: 0)
    var result: IOReturn
    if device.isConnected() {
        // This call waits for authentication to finish, using the existing pairing.
        result = device.requestAuthentication()
    } else {
        result = device.openConnection(nil, withPageTimeout: 8000, authenticationRequired: true)
        if result != 0 && device.isConnected() { result = device.requestAuthentication() }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    guard result == 0 && device.isConnected() && getppid() == parent else {
        send(connected: false, authenticated: false, status: result); exit(1)
    }
    // Keep this client alive for this connection. Dispose of it after a disconnect
    // so that the next attempt starts with a fresh IOBluetooth client.
    while device.isConnected() && getppid() == parent {
        send(connected: true, authenticated: true, status: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    send(connected: false, authenticated: false, status: 0)
    exit(0)
}

func runBluetoothWorkerIntegrationTest(address: String) {
    let worker = BluetoothConnectionWorker()
    worker.onChange = { print("Worker connection update:", worker.reportedConnected ?? false) }
    worker.start(address: address)
    let end = Date().addingTimeInterval(12)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        worker.checkTimeout(now: Date())
    }
    let success = worker.reportedConnected == true
    worker.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    print("Authenticated worker integration:", success ? "PASS" : "FAIL")
    exit(success ? 0 : 1)
}

final class BluetoothConnectionWorker {
    var onChange: (() -> Void)?
    private(set) var process: Process?
    private var pipe: Pipe?
    private var generation = UUID()
    private var bytes = Data()
    private var startedAt = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var authenticated = false
    private var snapshot: Bool?
    var isRunning: Bool { process?.isRunning == true }
    var connecting: Bool { isRunning && !authenticated }
    var reportedConnected: Bool? {
        guard let snapshot else { return nil }
        return snapshot && authenticated && isRunning && Date().timeIntervalSince(lastHeartbeat) < 4
    }
    func start(address: String) {
        guard process == nil, let executable = Bundle.main.executableURL else { return }
        let child = Process(); let output = Pipe(); let token = UUID()
        generation = token; bytes.removeAll(); authenticated = false; snapshot = false
        startedAt = Date(); lastHeartbeat = startedAt
        child.executableURL = executable
        child.arguments = ["--bluetooth-worker", address]
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data, token: token) }
        }
        child.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil; self.pipe = nil; self.authenticated = false; self.snapshot = false
                log("Bluetooth worker exited status=\(ended.terminationStatus)")
                self.onChange?()
            }
        }
        process = child; pipe = output
        do { try child.run(); log("Started fresh authenticated Bluetooth worker") }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            process = nil; pipe = nil; snapshot = false
            log("Bluetooth worker could not start: \(error.localizedDescription)")
        }
    }
    private func receive(_ data: Data, token: UUID) {
        guard generation == token else { return }
        bytes.append(data)
        guard bytes.count < 16_384 else { stop(); log("Bluetooth worker protocol exceeded its limit"); return }
        while let newline = bytes.firstIndex(of: 10) {
            let line = Data(bytes[..<newline]); bytes.removeSubrange(...newline)
            guard let packet = try? JSONDecoder().decode(BluetoothWorkerPacket.self, from: line) else { continue }
            let previous = snapshot
            authenticated = packet.authenticated && packet.status == 0
            snapshot = packet.connected && authenticated
            lastHeartbeat = Date()
            if previous != snapshot {
                log("Bluetooth worker authenticated connection=\(snapshot == true)")
                onChange?()
            }
        }
    }
    func checkTimeout(now: Date) {
        guard isRunning else { return }
        let expired = authenticated ? now.timeIntervalSince(lastHeartbeat) > 4 : now.timeIntervalSince(startedAt) > 9
        if expired { log("Bluetooth worker timed out; discarding this client before retry"); stop() }
    }
    func stop() {
        generation = UUID()
        let child = process
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil; pipe = nil; bytes.removeAll(); authenticated = false; snapshot = false
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    func reset() { stop(); snapshot = nil }
}
