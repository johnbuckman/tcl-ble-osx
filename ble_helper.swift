// ble_helper.swift
//
// Tcl BLE Library for OSX -- https://github.com/johnbuckman/tcl-ble-osx
// Copyright (C) 2026 John Buckman
// SPDX-License-Identifier: TCL
//
// CoreBluetooth <-> stdio bridge for the OSX "ble" Tcl package.
//
// This is the native half of an AndroWish-compatible `ble` command for
// undroidwish on macOS.  The Tcl side (ble.tcl) spawns this binary, talks to it
// over a tab-separated line protocol on stdin/stdout, and re-emits the events to
// the de1app exactly the way AndroWish's built-in `ble` command does.
//
// Why a separate process?  CoreBluetooth needs a live Objective-C run loop and a
// process whose Info.plist carries NSBluetoothAlwaysUsageDescription so macOS can
// grant Bluetooth (TCC) permission.  undroidwish is an x86_64 Tcl/Tk binary with
// none of that, so we keep the radio code here and pipe results back.
//
// macOS has no notion of a BLE MAC address: peripherals are identified by an
// opaque, host-stable NSUUID.  We use that UUID string as the "address" the
// de1app stores and reconnects with.  It is stable across launches for a given
// Mac+peripheral pair, which is exactly what the de1app needs.
//
// ---- Protocol ------------------------------------------------------------
//
// Commands  (Tcl -> helper), tab separated, one per line:
//   scan    start
//   scan    stop
//   connect <handle> <address> <reconnect>
//   close   <handle>
//   enable  <handle> <cinstance>
//   disable <handle> <cinstance>
//   write   <handle> <cinstance> <writetype> <hexdata>
//   read    <handle> <cinstance>
//   quit
//
// Events    (helper -> Tcl), tab separated, one per line:
//   state   <poweredOn|poweredOff|unauthorized|unsupported|resetting|unknown>
//   LOG     <text>
//   EV      scan           address=.. name=<hex> rssi=..
//   EV      connection     handle=.. address=.. state=connected mtu=..
//   EV      connection     handle=.. address=.. state=disconnected
//   EV      characteristic handle=.. address=.. state=discovery  suuid=.. sinstance=.. cuuid=.. cinstance=..
//   EV      characteristic handle=.. address=.. state=connected access=<r|w|c> suuid=.. sinstance=.. cuuid=.. cinstance=.. value=<hex>
//   EV      descriptor     handle=.. address=.. state=connected access=w suuid=.. sinstance=.. cuuid=.. cinstance=.. duuid=00002902-0000-1000-8000-00805F9B34FB
//
// `name` and `value` fields are hex encoded so the line protocol stays text-safe.

import Foundation
import CoreBluetooth
import Darwin

// ----------------------------------------------------------------------------
// Own our TCC (Bluetooth) identity.
//
// macOS attributes a TCC request to the "responsible process" -- normally the
// app that launched us.  Our launcher (undroidwish / wish) carries an appended
// VFS, so it cannot be code-signed and shows up to tccd as <InvalidCode>, which
// blocks the Bluetooth prompt.  By re-spawning ourselves with responsibility
// inheritance DISCLAIMED, this helper becomes its own responsible process, so
// tccd evaluates OUR ad-hoc signature + embedded NSBluetoothAlwaysUsageDescription
// and can present the prompt.  Works under any parent (undroidwish, Terminal...).
// ----------------------------------------------------------------------------
let DISCLAIM_FLAG = "--disclaimed"

func reexecOwningResponsibility() {
    // The argv marker is the loop guard -- robust regardless of env handling.
    if CommandLine.arguments.contains(DISCLAIM_FLAG) { return }
    if ProcessInfo.processInfo.environment["BLE_HELPER_NO_REEXEC"] != nil { return }

    // Signature: int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int);
    // -> takes the ADDRESS of the attr (&attr), not its value.
    typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
    guard let h = dlopen(nil, RTLD_NOW),
          let sym = dlsym(h, "responsibility_spawnattrs_setdisclaim") else { return }
    let setDisclaim = unsafeBitCast(sym, to: DisclaimFn.self)

    var size = UInt32(4096)
    var pathBuf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&pathBuf, &size) != 0 { return }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    _ = setDisclaim(&attr, 1)

    // Force the disclaimed child to inherit our stdio. The Tcl pipe lives on
    // fds 0 and 1; some parents open it close-on-exec (e.g. undroidwish's
    // `open "|helper" r+`), which would drop the fds across this re-exec --
    // the child would then have no pipe and Tcl would see "broken pipe" on its
    // first write. posix_spawn_file_actions_adddup2(fd,fd) keeps each fd open
    // in the child (POSIX: dup2 onto the same fd clears FD_CLOEXEC), so the
    // pipe survives the disclaim.
    //
    // ONLY dup 0 and 1. Do NOT touch fd 2: undroidwish's stderr is a "console2"
    // channel that is not a real fd, so adddup2(2,2) makes posix_spawn FAIL --
    // the disclaim then silently falls back to running in-process under the
    // unsignable host's identity, where TCC never grants Bluetooth (state stays
    // "unknown"). The helper doesn't need stderr (it logs via flog to a file).
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_adddup2(&fa, 0, 0)
    posix_spawn_file_actions_adddup2(&fa, 1, 1)

    // argv = original args + marker; environment passed through unchanged.
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(strdup(DISCLAIM_FLAG))
    argv.append(nil)

    var pid: pid_t = 0
    let rc = pathBuf.withUnsafeBufferPointer { pb in
        posix_spawn(&pid, pb.baseAddress, &fa, &attr, argv, environ)
    }
    posix_spawn_file_actions_destroy(&fa)
    posix_spawnattr_destroy(&attr)
    argv.forEach { if let p = $0 { free(p) } }

    // On success the disclaimed child inherits our stdio (the Tcl pipe) and
    // continues the protocol; exit so only one process talks to Tcl.  On
    // failure, fall through and run in-process.
    if rc == 0 { exit(0) }
}

// ----------------------------------------------------------------------------
// Small helpers
// ----------------------------------------------------------------------------

extension Data {
    var hex: String {
        var s = ""
        s.reserveCapacity(count * 2)
        for b in self { s += String(format: "%02x", b) }
        return s
    }
    init?(hex: String) {
        let chars = Array(hex)
        if chars.count % 2 != 0 { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(out)
    }
}

extension String {
    var hex: String { Data(self.utf8).hex }
}

// Long-form 128-bit UUID string, uppercase, matching how the de1app stores
// suuid/cuuid (e.g. "0000A000-0000-1000-8000-00805F9B34FB").
func longUUID(_ u: CBUUID) -> String {
    let s = u.uuidString.uppercased()
    if s.count == 4 {
        return "0000\(s)-0000-1000-8000-00805F9B34FB"
    } else if s.count == 8 {
        return "\(s)-0000-1000-8000-00805F9B34FB"
    }
    return s
}

let CCCD_UUID = "00002902-0000-1000-8000-00805F9B34FB"

// ----------------------------------------------------------------------------
// Output: all stdout writes go through one lock so lines never interleave.
// ----------------------------------------------------------------------------

// Diagnostic log to a fixed file -- survives regardless of the stdio pipe or
// TCC state, so we can tell whether the helper even launched and what
// CoreBluetooth state it reached.
// Off by default; set BLE_HELPER_DEBUG=1 in the environment to enable.
let flogEnabled = ProcessInfo.processInfo.environment["BLE_HELPER_DEBUG"] != nil
let flogLock = NSLock()
func flog(_ s: String) {
    guard flogEnabled else { return }
    flogLock.lock(); defer { flogLock.unlock() }
    if let f = fopen("/tmp/de1_ble_helper.log", "a") {
        fputs("[\(getpid())] \(s)\n", f); fclose(f)
    }
}

let outLock = NSLock()
func emit(_ parts: [String]) {
    let line = parts.joined(separator: "\t") + "\n"
    outLock.lock()
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    outLock.unlock()
}
func log(_ s: String) { emit(["LOG", s]) }

// ----------------------------------------------------------------------------
// Per-connection bookkeeping
// ----------------------------------------------------------------------------

final class Conn {
    let handle: String
    let address: String
    let peripheral: CBPeripheral
    var pendingServices = 0
    var connectedEmitted = false
    init(handle: String, address: String, peripheral: CBPeripheral) {
        self.handle = handle
        self.address = address
        self.peripheral = peripheral
    }
}

// Maps a synthetic cinstance back to the characteristic and its metadata.
final class CharRef {
    let conn: Conn
    let characteristic: CBCharacteristic
    let suuid: String
    let sinstance: Int
    let cuuid: String
    let cinstance: Int
    var lastWrite: Data = Data()
    var pendingRead = false
    init(conn: Conn, characteristic: CBCharacteristic, suuid: String, sinstance: Int, cuuid: String, cinstance: Int) {
        self.conn = conn
        self.characteristic = characteristic
        self.suuid = suuid
        self.sinstance = sinstance
        self.cuuid = cuuid
        self.cinstance = cinstance
    }
}

// ----------------------------------------------------------------------------
// The bridge
// ----------------------------------------------------------------------------

final class Bridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    let queue = DispatchQueue.main
    var central: CBCentralManager!

    var wantScan = false
    var poweredOn = false

    // Commands that arrived before the radio was poweredOn.
    var pendingConnects: [(handle: String, address: String)] = []

    var discovered: [String: CBPeripheral] = [:]   // address -> peripheral (from scanning)
    var connsByHandle: [String: Conn] = [:]         // handle  -> Conn
    var connsByPeripheral: [UUID: Conn] = [:]       // peripheral.identifier -> Conn

    var charsByInstance: [Int: CharRef] = [:]       // cinstance -> CharRef
    var charRefByObject: [ObjectIdentifier: CharRef] = [:]

    var instanceCounter = 0
    func nextInstance() -> Int { instanceCounter += 1; return instanceCounter }

    func start() {
        // queue: nil -> delegate callbacks arrive on the main run loop, which we
        // drive below with RunLoop.main.run().  CoreBluetooth's XPC link to
        // bluetoothd is serviced by that run loop; dispatchMain() does NOT
        // service it, so the state callback would never fire.
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // ---- CBCentralManagerDelegate ----------------------------------------

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let name: String
        switch central.state {
        case .poweredOn:    name = "poweredOn"; poweredOn = true
        case .poweredOff:   name = "poweredOff"
        case .unauthorized: name = "unauthorized"
        case .unsupported:  name = "unsupported"
        case .resetting:    name = "resetting"
        case .unknown:      name = "unknown"
        @unknown default:   name = "unknown"
        }
        flog("centralManagerDidUpdateState -> \(name) (authorization=\(CBManager.authorization.rawValue))")
        emit(["state", name])

        if central.state == .poweredOn {
            if wantScan { startScan() }
            let pend = pendingConnects
            pendingConnects.removeAll()
            for c in pend { doConnect(handle: c.handle, address: c.address) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let address = peripheral.identifier.uuidString.uppercased()
        discovered[address] = peripheral
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        emit(["EV", "scan",
              "address=\(address)",
              "name=\(name.hex)",
              "rssi=\(RSSI.intValue)"])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let conn = connsByPeripheral[peripheral.identifier] else { return }
        log("connected \(conn.address), discovering services")
        peripheral.delegate = self
        conn.connectedEmitted = false
        conn.pendingServices = 0
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "?")")
        if let conn = connsByPeripheral[peripheral.identifier] {
            emitDisconnect(conn)
            cleanup(conn)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let conn = connsByPeripheral[peripheral.identifier] else { return }
        log("disconnected \(conn.address): \(error?.localizedDescription ?? "clean")")
        emitDisconnect(conn)
        cleanup(conn)
    }

    func emitDisconnect(_ conn: Conn) {
        emit(["EV", "connection",
              "handle=\(conn.handle)",
              "address=\(conn.address)",
              "state=disconnected"])
    }

    func cleanup(_ conn: Conn) {
        connsByHandle.removeValue(forKey: conn.handle)
        connsByPeripheral.removeValue(forKey: conn.peripheral.identifier)
        for (inst, ref) in charsByInstance where ref.conn === conn {
            charsByInstance.removeValue(forKey: inst)
            charRefByObject.removeValue(forKey: ObjectIdentifier(ref.characteristic))
        }
    }

    // ---- CBPeripheralDelegate --------------------------------------------

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let conn = connsByPeripheral[peripheral.identifier] else { return }
        if let error = error { log("discoverServices error: \(error.localizedDescription)") }
        let services = peripheral.services ?? []
        conn.pendingServices = services.count
        if services.isEmpty { finishDiscovery(conn); return }
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let conn = connsByPeripheral[peripheral.identifier] else { return }
        if let error = error { log("discoverCharacteristics error: \(error.localizedDescription)") }
        let suuid = longUUID(service.uuid)
        let sinst = nextInstance()
        for c in service.characteristics ?? [] {
            let cuuid = longUUID(c.uuid)
            let cinst = nextInstance()
            let ref = CharRef(conn: conn, characteristic: c, suuid: suuid, sinstance: sinst, cuuid: cuuid, cinstance: cinst)
            charsByInstance[cinst] = ref
            charRefByObject[ObjectIdentifier(c)] = ref
            emit(["EV", "characteristic",
                  "handle=\(conn.handle)",
                  "address=\(conn.address)",
                  "state=discovery",
                  "suuid=\(suuid)",
                  "sinstance=\(sinst)",
                  "cuuid=\(cuuid)",
                  "cinstance=\(cinst)"])
        }
        conn.pendingServices -= 1
        if conn.pendingServices <= 0 { finishDiscovery(conn) }
    }

    func finishDiscovery(_ conn: Conn) {
        if conn.connectedEmitted { return }
        conn.connectedEmitted = true
        let mtu = conn.peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        emit(["EV", "connection",
              "handle=\(conn.handle)",
              "address=\(conn.address)",
              "state=connected",
              "mtu=\(mtu)"])
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let ref = charRefByObject[ObjectIdentifier(characteristic)] else { return }
        if let error = error { log("setNotify error \(ref.cuuid): \(error.localizedDescription)") }
        // The de1app advances its write queue on the CCCD ("descriptor") write ack.
        emit(["EV", "descriptor",
              "handle=\(ref.conn.handle)",
              "address=\(ref.conn.address)",
              "state=connected",
              "access=w",
              "suuid=\(ref.suuid)",
              "sinstance=\(ref.sinstance)",
              "cuuid=\(ref.cuuid)",
              "cinstance=\(ref.cinstance)",
              "duuid=\(CCCD_UUID)"])
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let ref = charRefByObject[ObjectIdentifier(characteristic)] else { return }
        if let error = error { log("write error \(ref.cuuid): \(error.localizedDescription)") }
        emitCharValue(ref, access: "w", value: ref.lastWrite)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let ref = charRefByObject[ObjectIdentifier(characteristic)] else { return }
        if let error = error { log("read/notify error \(ref.cuuid): \(error.localizedDescription)") }
        let access: String
        if ref.pendingRead { ref.pendingRead = false; access = "r" } else { access = "c" }
        emitCharValue(ref, access: access, value: characteristic.value ?? Data())
    }

    func emitCharValue(_ ref: CharRef, access: String, value: Data) {
        emit(["EV", "characteristic",
              "handle=\(ref.conn.handle)",
              "address=\(ref.conn.address)",
              "state=connected",
              "access=\(access)",
              "suuid=\(ref.suuid)",
              "sinstance=\(ref.sinstance)",
              "cuuid=\(ref.cuuid)",
              "cinstance=\(ref.cinstance)",
              "value=\(value.hex)"])
    }

    // ---- Commands from Tcl -----------------------------------------------

    func startScan() {
        guard poweredOn else { flog("startScan deferred (not poweredOn yet, state=\(central.state.rawValue))"); wantScan = true; return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        flog("scanForPeripherals called -> scanning started")
        log("scanning started")
    }

    func handle(command line: String) {
        flog("cmd: \(line)")
        let f = line.components(separatedBy: "\t")
        guard let cmd = f.first else { return }
        switch cmd {
        case "scan":
            if f.count >= 2 && f[1] == "start" { wantScan = true; startScan() }
            else { wantScan = false; if poweredOn { central.stopScan(); log("scanning stopped") } }

        case "connect":
            guard f.count >= 3 else { return }
            let handle = f[1]; let address = f[2].uppercased()
            if poweredOn { doConnect(handle: handle, address: address) }
            else { pendingConnects.append((handle, address)) }

        case "close":
            guard f.count >= 2 else { return }
            if let conn = connsByHandle[f[1]] {
                central.cancelPeripheralConnection(conn.peripheral)
            }

        case "enable", "disable":
            guard f.count >= 3, let inst = Int(f[2]), let ref = charsByInstance[inst] else { return }
            ref.conn.peripheral.setNotifyValue(cmd == "enable", for: ref.characteristic)

        case "write":
            guard f.count >= 5, let inst = Int(f[2]), let ref = charsByInstance[inst],
                  let data = Data(hex: f[4]) else { return }
            let wtype: CBCharacteristicWriteType = (f[3] == "1") ? .withoutResponse : .withResponse
            ref.lastWrite = data
            ref.conn.peripheral.writeValue(data, for: ref.characteristic, type: wtype)
            // .withResponse acks via didWriteValueFor; .withoutResponse has no
            // callback, so synthesise the write-ack the de1app's queue needs.
            if wtype == .withoutResponse {
                emitCharValue(ref, access: "w", value: data)
            }

        case "read":
            guard f.count >= 3, let inst = Int(f[2]), let ref = charsByInstance[inst] else { return }
            ref.pendingRead = true
            ref.conn.peripheral.readValue(for: ref.characteristic)

        case "quit":
            exit(0)

        default:
            log("unknown command: \(cmd)")
        }
    }

    func doConnect(handle: String, address: String) {
        var peripheral = discovered[address] ?? connsByPeripheral.values.first(where: { $0.address == address })?.peripheral
        if peripheral == nil, let uuid = UUID(uuidString: address) {
            peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
        }
        guard let p = peripheral else {
            log("connect: no peripheral for \(address); will appear via scan")
            // Remember the desired handle so a later scan hit can be connected by
            // the de1app re-issuing connect; nothing else to do here.
            return
        }
        let conn = Conn(handle: handle, address: address, peripheral: p)
        connsByHandle[handle] = conn
        connsByPeripheral[p.identifier] = conn
        p.delegate = self
        central.connect(p, options: nil)
        log("connecting \(handle) -> \(address)")
    }
}

// ----------------------------------------------------------------------------
// Wire up stdin reader + run loop
// ----------------------------------------------------------------------------

flog("=== ble_helper launched, args=\(CommandLine.arguments) ===")
reexecOwningResponsibility()
flog("running as responsible process; creating CBCentralManager")

let bridge = Bridge()
bridge.start()
flog("CBCentralManager created; entering run loop")

// Read stdin on a background thread; dispatch each command onto the BLE queue
// so all CoreBluetooth state is touched from one place.
let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        bridge.queue.async { bridge.handle(command: line) }
    }
    // stdin closed -> parent went away -> exit.
    exit(0)
}
reader.stackSize = 1 << 20
reader.start()

// Drive the main run loop: CoreBluetooth delegate callbacks AND
// DispatchQueue.main.async blocks (our command handling) are serviced here.
RunLoop.main.run()
