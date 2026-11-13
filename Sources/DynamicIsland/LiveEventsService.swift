import AppKit
import Foundation
import IOBluetooth
import IOKit.ps
import SwiftUI

/// Цвета «живых» событий — те же, что в версии для Windows.
enum LiveTint {
    static let green = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
    static let red = Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
    static let gray = Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
}

// MARK: - зарядка

/// Подключение / отключение зарядки и предупреждения о низком заряде (20 % и 10 %).
/// Логика 1-в-1 как в LiveEventsService.cs (Windows). Колбэк вызывается на главном потоке.
final class PowerEventsService {
    /// событие и сколько секунд его показывать
    var onEvent: ((LiveActivity, Double) -> Void)?

    private var timer: Timer?
    private var lastOnline: Bool?
    private var warned20 = false
    private var warned10 = false

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }

    /// Заряд встроенного аккумулятора и подключена ли зарядка. nil — у Mac нет батареи.
    static func read() -> (pct: Int, online: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (desc[kIOPSTypeKey] as? String) != kIOPSInternalBatteryType { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            guard cur >= 0, max > 0 else { return nil }
            let pct = min(100, Int((Double(cur) * 100 / Double(max)).rounded()))
            // «От сети» — даже если macOS держит заряд на 80 % и сейчас не заряжает
            let online = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (pct, online)
        }
        return nil
    }

    private func poll() {
        guard let state = Self.read() else { return }   // Mac без батареи
        let pct = state.pct, online = state.online

        let prev = lastOnline
        lastOnline = online

        if online { warned20 = false; warned10 = false }

        if let prev, prev != online {
            let title = online ? Loc.t(pct >= 100 ? "ev_full" : "ev_charging") : Loc.t("ev_onbattery")
            let tint: Color? = online ? LiveTint.green : (pct <= 20 ? LiveTint.red : nil)
            onEvent?(LiveActivity(symbol: Self.symbol(pct, charging: online), title: title, value: "\(pct)%", tint: tint), 2.2)
            return
        }

        if !online && prev != nil {
            var warn = false
            if pct <= 10 && !warned10 { warned10 = true; warned20 = true; warn = true }
            else if pct <= 20 && !warned20 { warned20 = true; warn = true }
            if warn {
                onEvent?(LiveActivity(symbol: Self.symbol(pct, charging: false), title: Loc.t("ev_lowbattery"),
                                      value: "\(pct)%", tint: LiveTint.red), 3.5)
            }
        } else if prev == nil && !online {
            // при запуске уже разряжено — не пугаем сразу, но и не повторяем предупреждение
            if pct <= 10 { warned10 = true; warned20 = true }
            else if pct <= 20 { warned20 = true }
        }
    }

    /// SF Symbols, доступные с macOS 13.
    static func symbol(_ pct: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Bluetooth-наушники

/// Подключение / отключение Bluetooth-наушников и колонок с зарядом (если устройство его сообщает).
/// Мыши, клавиатуры, телефоны и т. п. не показываются. Колбэк вызывается на главном потоке.
final class BluetoothEventsService: NSObject {
    var onEvent: ((LiveActivity, Double) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    /// адреса подключённых сейчас устройств (только главный поток)
    private var connected: Set<String> = []

    func start() {
        // уже подключённые при запуске — молча запоминаем, чтобы не показывать их
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for d in paired where d.isConnected() {
            let addr = Self.normalize(d.addressString)
            guard !addr.isEmpty else { continue }
            connected.insert(addr)
            watchDisconnect(d, addr)
        }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes.removeAll()
    }

    deinit { stop() }

    private func watchDisconnect(_ d: IOBluetoothDevice, _ addr: String) {
        disconnectNotes[addr]?.unregister()
        disconnectNotes[addr] = d.register(forDisconnectNotification: self,
                                           selector: #selector(deviceDisconnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        guard let device else { return }
        let addr = Self.normalize(device.addressString)
        guard !addr.isEmpty, !connected.contains(addr) else { return }
        connected.insert(addr)
        watchDisconnect(device, addr)

        guard Self.isAudio(device) else { return }
        let name = Self.displayName(device)
        let symbol = Self.symbol(device, name)

        // заряд наушники присылают через пару секунд после подключения
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var battery = Self.readBattery(address: addr)
            if battery == nil {
                Thread.sleep(forTimeInterval: 2)
                battery = Self.readBattery(address: addr)
            }
            DispatchQueue.main.async {
                guard let self, self.connected.contains(addr) else { return }
                let value = battery.map { "\($0)%" } ?? Loc.t("ev_bt_connected")
                let tint: Color? = (battery ?? 100) <= 20 ? LiveTint.red : nil
                self.onEvent?(LiveActivity(symbol: symbol, title: name, value: value, tint: tint), 2.6)
            }
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        note?.unregister()
        guard let device else { return }
        let addr = Self.normalize(device.addressString)
        guard !addr.isEmpty else { return }
        disconnectNotes[addr] = nil
        connected.remove(addr)

        guard Self.isAudio(device) else { return }
        let name = Self.displayName(device)
        let symbol = Self.symbol(device, name)

        // короткие «моргания» соединения не показываем
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.connected.contains(addr), !device.isConnected() else { return }
            self.onEvent?(LiveActivity(symbol: symbol, title: name, value: Loc.t("ev_bt_disconnected"),
                                       tint: LiveTint.gray), 2.6)
        }
    }

    // MARK: определение устройства

    private static func normalize(_ address: String?) -> String {
        (address ?? "").uppercased().filter { $0.isHexDigit }
    }

    private static func displayName(_ d: IOBluetoothDevice) -> String {
        let n = (d.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Bluetooth" : n
    }

    private static let audioHints = ["airpods", "buds", "headphone", "headset", "наушник", "wh-", "wf-", "jbl",
                                     "beats", "earbuds", "pods", "marshall", "sony", "bose", "sennheiser"]

    /// Class of Device: Major 0x04 — Audio/Video (наушники, гарнитуры, колонки).
    private static func isAudio(_ d: IOBluetoothDevice) -> Bool {
        if Int(d.deviceClassMajor) == 0x04 { return true }
        // запасной вариант — по названию
        let n = (d.name ?? "").lowercased()
        return audioHints.contains { n.contains($0) }
    }

    /// Minor 0x05 — колонка (Loudspeaker).
    private static func symbol(_ d: IOBluetoothDevice, _ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if Int(d.deviceClassMajor) == 0x04 && Int(d.deviceClassMinor) == 0x05 { return "hifispeaker" }
        return "headphones"
    }

    // MARK: заряд

    /// Заряд из «Информации о системе» (то же, что показывает меню Bluetooth).
    /// У AirPods — общий заряд или меньший из левого/правого наушника (кейс не учитывается).
    private static func readBattery(address: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data),
              let info = findDevice(root, address: address) else { return nil }

        func level(_ key: String) -> Int? {
            guard let s = info[key] as? String else { return nil }
            let digits = s.filter { $0.isNumber }
            guard let v = Int(digits), (0...100).contains(v) else { return nil }
            return v
        }

        if let main = level("device_batteryLevelMain") ?? level("device_batteryLevel") { return main }
        let buds = [level("device_batteryLevelLeft"), level("device_batteryLevelRight")].compactMap { $0 }
        return buds.min()
    }

    /// Ищет описание устройства с нужным адресом в любом месте JSON (формат отличается между версиями macOS).
    private static func findDevice(_ obj: Any, address: String) -> [String: Any]? {
        if let dict = obj as? [String: Any] {
            if let a = dict["device_address"] as? String, normalize(a) == address { return dict }
            for v in dict.values {
                if let found = findDevice(v, address: address) { return found }
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                if let found = findDevice(v, address: address) { return found }
            }
        }
        return nil
    }
}
