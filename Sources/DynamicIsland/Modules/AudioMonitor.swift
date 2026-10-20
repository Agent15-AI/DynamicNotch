import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// CoreAudio property listeners for the default output device.
///
/// Serves two jobs that need the same device plumbing: the volume HUD, and the
/// gate that decides whether the Now Playing helper should be running at all.
/// Entirely event-driven - CoreAudio calls us, we never poll.
@MainActor
@Observable
final class AudioMonitor {
    static let shared = AudioMonitor()

    private(set) var volume: Float = 0
    private(set) var muted = false
    /// Bumped whenever the set of processes outputting audio changes.
    ///
    /// Device-level `IsRunningSomewhere` is useless as a gate - it reads true
    /// permanently on any Mac running Chrome, which holds an output stream open
    /// whether or not anything is playing. The per-process list at least tells us
    /// when something new starts, which is when Now Playing is worth checking.
    private(set) var outputChangeCount = 0
    private(set) var outputtingPIDs: Set<pid_t> = []

    /// Processes currently capturing audio input, for the microphone indicator.
    ///
    /// Free to know: the per-process objects are already bound for the output
    /// gate above, and input is one more property on the same objects. There is
    /// no separate device-level listener and nothing polls.
    ///
    /// There is deliberately no camera equivalent. CoreMediaIO is the obvious
    /// twin of this API and measured 25% CPU with memory climbing 26 MB to 65 MB
    /// in 40 seconds - enumerating its device list loads every DAL plugin, and
    /// the device-list listener re-fires on the query. It would also be telling
    /// you what the hardware already does: the green LED beside the camera is
    /// wired to the sensor's power and cannot be lied to. The microphone has no
    /// such light, which is the whole reason this half is worth having.
    private(set) var inputtingPIDs: Set<pid_t> = []

    /// Whether anything is capturing, from the input device rather than from the
    /// process list.
    ///
    /// This is the truth and the process list is only used to name the app. The
    /// per-process flag misses captures: a process that appears and opens the
    /// input in the same instant flips `IsRunningInput` before a listener can be
    /// bound to it, and nothing re-reads afterwards - measured as the microphone
    /// indicator working on one launch and not the next. The device-level flag
    /// never misses it.
    ///
    /// Safe here in a way it is not for output. `IsRunningSomewhere` is useless
    /// as an output gate because Chrome holds an output stream open forever;
    /// measured on the input device it reads false at rest and flips only for a
    /// real capture.
    private(set) var micRunning = false

    /// Bumped only when the microphone goes on or off, so a second app joining a
    /// call does not announce itself again.
    private(set) var inputChangeCount = 0

    /// Bumped whenever the set of audio processes changes - an app opening or
    /// closing audio, not merely starting or stopping a sound. The mixer lists
    /// every app holding a connection, so that is the change it has to see.
    private(set) var processChangeCount = 0

    var micActive: Bool { Settings.shared.recording && micRunning }

    /// One name, not a list - several processes can hold the input at once (a
    /// call app and its helper, say) and the label has room for one.
    var micApp: String? {
        inputtingPIDs
            .compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            .sorted()
            .first
    }

    private var device = AudioDeviceID(0)
    private var blocks: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {}

    func start() {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindDefaultDevice() }
        }
        bindDefaultDevice()
        watchProcesses()
        watchInput()
    }

    // MARK: - Input device

    private var inputBlock: (AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?

    private func watchInput() {
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindInputDevice() }
        }
        bindInputDevice()
    }

    private func bindInputDevice() {
        if let (id, addr, block) = inputBlock {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
            inputBlock = nil
        }
        guard let id = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return }
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readRunning() }
        }
        if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
            inputBlock = (id, addr, block)
        }
        readRunning()
    }

    private func bindDefaultDevice() {
        unbind()
        guard let id = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return }
        device = id
        listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput) { [weak self] in
            self?.readVolume()
        }
        listen(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) { [weak self] in
            self?.readMute()
        }
        readVolume(); readMute()
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ handler: @escaping () -> Void) {
        var addr = Self.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, block) == noErr {
            blocks.append((device, addr, block))
        }
    }

    private func unbind() {
        for (id, addr, block) in blocks {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        blocks.removeAll()
    }

    private func readVolume() {
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr { volume = value }
    }

    private func readMute() {
        var addr = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr { muted = value != 0 }
    }

    // MARK: - Setting output volume

    /// Sets the default output device's volume.
    ///
    /// The listener bound in `bindDefaultDevice` reports the change straight
    /// back, so the published value follows the hardware rather than being
    /// guessed here - which is what keeps a slider honest when the volume keys
    /// are used at the same time.
    func setVolume(_ value: Float) {
        guard device != 0 else { return }
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                kAudioObjectPropertyScopeOutput)
        var level = min(max(value, 0), 1)
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &level)
        // Raising the volume on a muted device should unmute it, the way the
        // volume keys do.
        if level > 0, muted { setMuted(false) }
    }

    func setMuted(_ value: Bool) {
        guard device != 0 else { return }
        var addr = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var flag: UInt32 = value ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &flag)
    }

    /// Name of the device sound is going to, for the row's label.
    var currentOutputName: String {
        outputs.first { $0.id == device }?.name ?? "Output"
    }

    // MARK: - Per-process output

    private var processBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private func watchProcesses() {
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRebind() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        rebindProcesses()
    }

    /// Coalesces a burst of CoreAudio notifications into one pass.
    ///
    /// Both of these are storms, not single events. Browsers and chat apps open
    /// and close audio constantly, and every change fired a full rebind - drop
    /// and re-add a listener for every process, twice over since input is
    /// watched as well as output, then re-enumerate the lot. Sampled at 0.8%
    /// CPU and about one wakeup a second on a closed island, all of it inside
    /// `rebindProcesses`.
    ///
    /// One cancellable work item each, no timer: a burst settles into a single
    /// pass, and a quiet machine schedules nothing at all.
    private var rebindWork: DispatchWorkItem?
    private var readWork: DispatchWorkItem?

    private func scheduleRebind() {
        rebindWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebindProcesses() }
        rebindWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scheduleRead() {
        readWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readRunning() }
        readWork = work
        // Shorter than the rebind: this is what drives the microphone indicator,
        // and a fifth of a second is still imperceptible there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func rebindProcesses() {
        rebindWork?.cancel()
        for (id, addr, block) in processBlocks {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        processBlocks.removeAll()
        processChangeCount += 1

        for id in Self.processObjects() {
            for selector in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput] {
                var addr = Self.address(selector, kAudioObjectPropertyScopeGlobal)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleRead() }
                }
                if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                    processBlocks.append((id, addr, block))
                }
            }
        }
        readRunning()
    }

    private func readRunning() {
        // One listing serves both sets - the process list is the expensive part
        // of this read, and it is the same list for input and output.
        let processes = Self.processObjects()

        let outputting = Set(processes.filter { Self.isRunning($0, kAudioProcessPropertyIsRunningOutput) }.map(Self.pid))
        if outputting != outputtingPIDs {
            outputtingPIDs = outputting
            outputChangeCount += 1
        }

        // Never ourselves. The mixer's aggregate device carries its process tap
        // as an input stream, so starting it registers this app as capturing -
        // and the microphone activity then announced "DynamicIsland" as the app
        // listening, every time a per-app volume was turned down.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let inputting = Set(
            processes.filter { Self.isRunning($0, kAudioProcessPropertyIsRunningInput) }
                .map(Self.pid)
                .filter { $0 != ownPID }
        )
        if inputting != inputtingPIDs { inputtingPIDs = inputting }

        let running = Self.isDeviceRunning(inputBlock?.0)
        guard running != micRunning else { return }
        micRunning = running
        // On and off, not every change of membership.
        inputChangeCount += 1
        // The device flips before the process list catches up, so the app name
        // is usually not there yet on the first read. One delayed re-read, no
        // timer - and it only ever runs on a real transition.
        guard running, inputtingPIDs.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, micRunning else { return }
            let late = Set(Self.processObjects().filter { Self.isRunning($0, kAudioProcessPropertyIsRunningInput) }.map(Self.pid))
            if late != inputtingPIDs { inputtingPIDs = late }
        }
    }

    private static func isDeviceRunning(_ id: AudioDeviceID?) -> Bool {
        guard let id else { return false }
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func isRunning(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pid(_ id: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    // MARK: - Output devices

    struct Output: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        /// Stable across relaunches and reconnects, unlike the device id. The
        /// mixer's aggregate devices are described by UID, so routing needs it.
        let uid: String
        /// How the device is attached, from CoreAudio. An AirPlay speaker is
        /// already in this list once macOS knows about it - what was missing was
        /// any way to tell it apart from the built-in speakers, which is the
        /// whole reason the menu now carries a glyph per device.
        let transport: UInt32

        var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }

        /// Named after the connection, so the row says how the sound gets there.
        var symbol: String {
            switch transport {
            case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
            case kAudioDeviceTransportTypeUSB: "cable.connector"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: "square.stack.3d.up"
            default: "speaker.wave.2"
            }
        }
    }

    /// Output devices that can currently be selected.
    var outputs: [Output] { Self.devices(scope: kAudioDevicePropertyScopeOutput) }

    /// Microphones. Listed beside the outputs because connecting headphones
    /// moves both, and the headset microphone is often the one you did not want.
    var inputs: [Output] { Self.devices(scope: kAudioDevicePropertyScopeInput) }

    var currentInput: AudioDeviceID? { Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    func selectInput(_ id: AudioDeviceID) {
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [Output] {
        var addr = Self.address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard Self.hasStreams(id, scope: scope), let name = Self.name(of: id),
                  let uid = Self.uid(of: id),
                  // Our own private devices are visible to us and nobody else.
                  // A mixer engine or the sound graph's listener offered as an
                  // output, or anything of ours offered as a microphone, loops
                  // audio back into itself. The multi-output is the one that is
                  // a real output, and only as one.
                  !uid.hasPrefix("dev.local.dynamicisland.")
                      || (scope == kAudioDevicePropertyScopeOutput && uid == "dev.local.dynamicisland.multioutput")
            else { return nil }
            return Output(id: id, name: name, uid: uid, transport: Self.transport(of: id))
        }
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    var currentOutput: AudioDeviceID { device }

    func selectOutput(_ id: AudioDeviceID) {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var value = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &value)
    }

    /// Input-only devices would otherwise show up in the output list, and the
    /// other way round.
    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        let uid = value as String
        return uid.isEmpty ? nil : uid
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        let name = value as String
        return name.isEmpty ? nil : name
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

