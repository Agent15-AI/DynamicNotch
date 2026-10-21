import AppKit
import CoreBluetooth
import IOBluetooth

/// Bluetooth connect/disconnect, for the live activity.
///
/// IOBluetooth calls us on connection changes, so there is no scanning and no
/// polling - registering an inquiry would keep the radio busy for no reason.
// ponytail: no @Observable. This class publishes nothing - it pushes straight
// into HUD - and the macro traps on an NSObject subclass, which IOBluetooth
// requires for its target/selector callbacks.
@MainActor
final class BluetoothWatch: NSObject {
    static let shared = BluetoothWatch()

    private var disconnectHandles: [String: IOBluetoothUserNotification] = [:]

    private override init() { super.init() }

    /// True once macOS has granted Bluetooth. Reading this never prompts, which
    /// is the whole point: the first call into IOBluetooth is what raises the
    /// dialog, so an app that has not been granted must not make that call on
    /// its own. Otherwise every launch asks again - and because a TCC grant is
    /// keyed to the code signature, every rebuild asks again too.
    var authorized: Bool { CBCentralManager.authorization == .allowedAlways }

    func start() {
        guard Settings.shared.bluetooth, authorized else { return }
        connect()
    }

    /// Deliberately raises the permission dialog. Only ever called from the
    /// button in Settings, so the prompt always follows an explicit request.
    func requestAccess() {
        // Refused once, macOS never asks again - the pane is the only way back.
        guard CBCentralManager.authorization != .denied else {
            Permissions.open("Privacy_Bluetooth")
            return
        }
        connect()
    }

    private func connect() {
        IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        // Devices already paired and connected at launch still need a disconnect
        // hook, or the first unpair after launch goes unnoticed.
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        where device.isConnected() {
            watchDisconnect(device)
        }
    }

    // `nonisolated`, then a hop to the main thread. IOBluetooth delivers these
    // on whatever queue CoreBluetooth posted from, and on macOS 26 that is not
    // the main one: the actor check in a main-actor method's `@objc` entry
    // point trapped and took the whole app down when a device connected.
    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.watchDisconnect(device)
                self.announce(device, connected: true)
            }
        }
    }

    @objc nonisolated private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let address = device.addressString {
                    self.disconnectHandles[address]?.unregister()
                    self.disconnectHandles[address] = nil
                }
                self.announce(device, connected: false)
            }
        }
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, disconnectHandles[address] == nil else { return }
        disconnectHandles[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
    }

    private func announce(_ device: IOBluetoothDevice, connected: Bool) {
        guard Settings.shared.bluetooth else { return }
        let name = device.name ?? device.addressString ?? "Device"
        let symbol = Self.symbol(for: device)
        let show = { @MainActor in
            // The level if the accessory already publishes one; a keyboard does
            // the moment it connects, AirPods a beat later.
            DeviceBatteries.shared.refresh()
            let battery = connected ? DeviceBatteries.shared.percent(forName: name) : nil
            HUD.shared.show(.bluetooth(name: name, symbol: symbol, connected: connected, battery: battery), for: 2.2)
        }
        if connected { DeviceBatteries.shared.check(after: 4) }
        show()
    }

    /// Best-guess glyph from the Bluetooth class of device, so headphones do not
    /// show a generic dot.
    private static func symbol(for device: IOBluetoothDevice) -> String {
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio): "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral): "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone): "iphone"
        case UInt32(kBluetoothDeviceClassMajorComputer): "laptopcomputer"
        default: "dot.radiowaves.left.and.right"
        }
    }
}
