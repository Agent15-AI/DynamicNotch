import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import os

/// Per-app volume, which macOS does not offer.
///
/// For each app you turn down, a **muted** process tap removes that app's audio
/// from the normal output, and a private aggregate device re-renders the tapped
/// stream at the gain you chose. An app left at 100% has no tap and no engine -
/// it is untouched, and costs nothing.
///
/// That last sentence is the whole power story, and it is also the cost: while
/// any app *is* turned down, a CoreAudio render callback runs for as long as it
/// stays down. This is the one feature in the app that is not free at rest, and
/// it is deliberately the only one.
///
/// Needs macOS 14.4 for process taps, and the System Audio Recording permission
/// the first time a tap is created.
///
/// Idea borrowed from Vorssaint's mixer; implementation here is this project's
/// own.
@MainActor
@Observable
final class VolumeMixer {
    static let shared = VolumeMixer()

    struct App: Identifiable, Equatable {
        let id: pid_t
        /// Bundle id where there is one, else the name. Volumes are remembered
        /// under this rather than the pid, which recycles.
        let key: String
        let name: String
        let icon: NSImage?
        let objects: [AudioObjectID]
        var volume: Double
        var playing: Bool
        /// UID of the device this app is sent to, or nil for the system default.
        var route: String?
    }

    private(set) var apps: [App] = []

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private init() {}

    // MARK: - Listing

    /// Rebuilt when the mixer is on screen and whenever the set of audio
    /// processes changes. Never on a timer.
    func refresh() {
        // Switched off means every app back at full volume, not left wherever
        // it was turned down to with no slider on screen to undo it.
        guard Settings.shared.mixer, Self.isSupported else { apps = []; stopAll(); return }

        // Every app that holds an audio connection, not only the ones making a
        // sound this instant. Presence in the process object list *is* the test
        // - a process appears there once it has opened audio and stays while it
        // holds it. Filtering on `IsRunningOutput` as well left the list empty
        // whenever nothing happened to be playing, which is exactly when you
        // want to set a level in advance.
        var grouped: [pid_t: (app: NSRunningApplication, objects: [AudioObjectID], playing: Bool)] = [:]
        let ownPid = ProcessInfo.processInfo.processIdentifier

        for object in Self.processObjects() {
            let pid = Self.pid(object)
            guard pid > 0, pid != ownPid else { continue }
            // Helpers roll up into the app that owns them - a browser plays
            // through a GPU process, and a row called "com.apple.WebKit.GPU"
            // helps nobody.
            guard let (owner, app) = Self.regularOwner(of: pid) else { continue }

            let playing = Self.isRunningOutput(object)
            if var existing = grouped[owner] {
                existing.objects.append(object)
                existing.playing = existing.playing || playing
                grouped[owner] = existing
            } else {
                grouped[owner] = (app, [object], playing)
            }
        }

        apps = grouped.map { owner, entry in
            let name = entry.app.localizedName ?? "pid \(owner)"
            let key = entry.app.bundleIdentifier ?? name
            return App(
                id: owner,
                key: key,
                name: name,
                icon: entry.app.icon,
                objects: entry.objects.sorted(),
                volume: stored[key] ?? 1.0,
                playing: entry.playing,
                route: routes[key]
            )
        }
        .sorted {
            $0.playing == $1.playing
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.playing && !$1.playing
        }

        // An app that quit should not keep an engine running for it.
        for pid in engines.keys where !apps.contains(where: { $0.id == pid }) {
            teardown(pid)
        }
    }

    /// The regular app behind an audio process.
    ///
    /// Three steps, because audio rarely comes from the app you see. The
    /// responsible process is what macOS itself blames for a helper's
    /// behaviour, so it is tried first; then the process itself; then a short
    /// walk up the parent chain. Anything that never resolves to an app with a
    /// Dock icon - daemons, `afplay`, agents - gets no row, because a slider
    /// for it would control something the user cannot point at.
    private static func regularOwner(of pid: pid_t) -> (pid_t, NSRunningApplication)? {
        var candidates: [pid_t] = []
        if let responsible = responsibleOwner(pid), responsible > 0 { candidates.append(responsible) }
        candidates.append(pid)

        var walk = parent(of: pid)
        var hops = 0
        while walk > 1, hops < 4 {
            candidates.append(walk)
            walk = parent(of: walk)
            hops += 1
        }

        for candidate in candidates {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy == .regular {
                return (candidate, app)
            }
        }
        return nil
    }

    /// `responsibility_get_pid_responsible_for_pid` is not in the SDK, so it is
    /// resolved at runtime and the lookup degrades to the parent walk if it ever
    /// disappears.
    private nonisolated static func responsibleOwner(_ pid: pid_t) -> pid_t? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)(pid)
    }

    private nonisolated static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Volume

    private var stored: [String: Double] = [:]

    /// Per-app output device, by the same stable key as the volume.
    ///
    /// The aggregate device is built around one output, so changing where an app
    /// goes means building a new engine rather than retuning the old one.
    private(set) var routes: [String: String] = [:]

    func setRoute(_ uid: String?, for app: App) {
        if let uid { routes[app.key] = uid } else { routes.removeValue(forKey: app.key) }
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].route = uid }

        teardown(app.id)
        let gain = stored[app.key] ?? 1
        // An app on the default device at unity needs no engine at all.
        guard needsEngine(app.key) else { return }
        start(app, gain: Float(gain))
    }

    /// Output devices an app can be sent to.
    var outputs: [AudioMonitor.Output] { AudioMonitor.shared.outputs }

    /// Volume can exceed unity. The render callback already multiplies by the
    /// gain, so boosting is the same code path - the ceiling was the only thing
    /// stopping it. Capped at 2x: past that clipping is audible on most material
    /// and the control stops being useful.
    static let maximumGain = 2.0

    func setVolume(_ value: Double, for app: App) {
        let clamped = min(max(value, 0), Self.maximumGain)
        stored[app.key] = clamped
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].volume = clamped
        }

        // Unity on the default device means "leave it alone": tear the engine
        // down rather than running a callback that multiplies by one.
        guard needsEngine(app.key) else {
            teardown(app.id)
            return
        }
        if let engine = engines[app.id] {
            engine.gain.withLock { $0 = Float(clamped) }
        } else {
            start(app, gain: Float(clamped))
        }
    }

    /// Whether this app needs an engine at all: turned down, boosted, or sent
    /// somewhere other than the system output.
    ///
    /// One predicate, because it is asked twice - once to decide whether to
    /// build, and again when the build lands to check the answer has not changed
    /// meanwhile. Those two had drifted apart, and everything above unity or
    /// routed at unity was built and then immediately thrown away.
    private func needsEngine(_ key: String) -> Bool {
        let volume = stored[key] ?? 1
        return volume < 0.999 || volume > 1.001 || routes[key] != nil
    }

    var isRouting: Bool { !engines.isEmpty }

    // MARK: - Engines

    /// One per app that is currently turned down.
    private var engines: [pid_t: Engine] = [:]

    /// Holds everything CoreAudio needs torn down again, and the gain the render
    /// callback reads. The gain lives behind a lock because the callback runs on
    /// a real-time thread that must never touch the main actor.
    private final class Engine: @unchecked Sendable {
        var tap: AudioObjectID = 0
        var aggregate: AudioObjectID = 0
        var procID: AudioDeviceIOProcID?
        /// Device this engine was built around. An aggregate is built for one
        /// output and cannot be repointed, so following the system output means
        /// comparing against this and rebuilding when it no longer matches.
        var outputUID = ""
        /// The app's stable key, so the check below can tell an engine that is
        /// following the default from one the user pointed somewhere on purpose
        /// without needing the `apps` list to be current.
        var key = ""
        let gain = OSAllocatedUnfairLock<Float>(initialState: 1)
    }

    // MARK: - Following the system output

    /// Rebuilds the apps that are set to "System output" when that output
    /// changes.
    ///
    /// The device is resolved once, when the engine is built, and baked into the
    /// aggregate. So an app left on the system output stayed pinned to whatever
    /// happened to be default at that moment: turn an app down while the
    /// speakers are default, plug headphones in, and macOS moves - but that app
    /// keeps playing out loud, with the menu still correctly reading "System
    /// output". Unplugging was the same bug in reverse, with the app rendering
    /// into a device that had gone away.
    ///
    /// CoreAudio posts the change, so this costs nothing until it happens, and
    /// the listener is only registered once an engine actually exists.
    private var watchingDefault = false

    private func watchDefaultOutput() {
        guard !watchingDefault else { return }
        watchingDefault = true
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDefaultOutput() }
        }
    }

    /// An app with its own route asked for a specific device and must not be
    /// moved - only the ones following the default are rebuilt.
    private func followDefaultOutput() {
        guard !engines.isEmpty, let current = Self.defaultOutputUID() else { return }
        // Cheap test first. Re-listing the audio processes is the expensive part
        // and this also runs after every engine build, so it must not happen
        // unless something is genuinely pointing at the wrong device.
        guard engines.values.contains(where: {
            routes[$0.key] == nil && $0.outputUID != current
        }) else { return }
        // `refresh()` is otherwise only driven by the mixer tab being on screen,
        // so with the island shut `apps` can be older than the engines are.
        refresh()
        for app in apps where app.route == nil {
            guard let engine = engines[app.id], engine.outputUID != current else { continue }
            teardown(app.id)
            start(app, gain: Float(stored[app.key] ?? 1))
        }
    }

    /// Builds the engine **off the main thread**.
    ///
    /// Creating the tap raises the media-library permission dialog the first
    /// time, and a TCC dialog blocks the thread that triggered it until it is
    /// answered. Doing this on the main thread froze the whole island behind a
    /// dialog - measured, not theorised. Same lesson as the folder probes.
    private func start(_ app: App, gain: Float) {
        guard #available(macOS 14.4, *) else { return }
        // Where this app should come out: its own route if it has one, else
        // wherever the system is pointing.
        guard let outputUID = routes[app.key] ?? Self.defaultOutputUID() else { return }
        guard !starting.contains(app.id) else { return }

        watchDefaultOutput()
        starting.insert(app.id)
        let objects = app.objects
        let name = app.name
        let pid = app.id
        let key = app.key

        DispatchQueue.global(qos: .userInitiated).async {
            let engine = Self.buildEngine(objects: objects, name: name,
                                          outputUID: outputUID, gain: gain)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.starting.remove(pid)
                    guard let engine else {
                        // Nothing to hear and, until now, nothing to see: the
                        // slider moved, the percentage changed and the audio did
                        // not, with no way to tell a denied permission from a
                        // device that refused. Creating the tap is what raises
                        // the System Audio Recording prompt, so a decline lands
                        // exactly here.
                        NSLog("mixer: could not build engine for \(name)")
                        HUD.shared.show(
                            .utility(symbol: "speaker.slash.fill",
                                     title: name,
                                     detail: "Allow System Audio Recording"),
                            for: 3.4
                        )
                        // Snap back, so the control never sits at a level the
                        // audio is not actually at.
                        self.stored[key] = 1
                        if let index = self.apps.firstIndex(where: { $0.id == pid }) {
                            self.apps[index].volume = 1
                        }
                        return
                    }
                    // Back at unity while we were building, or the app quit:
                    // throw the engine away rather than leaving it running.
                    guard self.needsEngine(key) else {
                        Self.destroy(engine)
                        return
                    }
                    if let existing = self.engines[pid] { Self.destroy(existing) }
                    // The build took the gain of the first drag event. Every
                    // event after it found a build in flight and only stored its
                    // value, so the slider ended at 30% with the audio at 98%.
                    let latest = Float(self.stored[key] ?? 1)
                    engine.gain.withLock { $0 = latest }
                    engine.key = key
                    self.engines[pid] = engine
                    // The default output can move while a build is in flight, in
                    // which case this engine landed already pointing at the old
                    // device. Idempotent: a no-op once the UIDs agree, so this
                    // settles rather than looping.
                    self.followDefaultOutput()
                }
            }
        }
    }

    /// Apps whose engine is mid-build, so a second drag does not start two.
    private var starting: Set<pid_t> = []

    private nonisolated static func buildEngine(
        objects: [AudioObjectID], name: String, outputUID: String, gain: Float
    ) -> Engine? {
        guard #available(macOS 14.4, *) else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "Dynamic Island \(name)"
        description.isPrivate = true
        // Muted: the app's own sound stops reaching the output, and what the
        // listener hears is entirely what this engine renders. Without this the
        // app would be audible twice, once at full volume.
        description.muteBehavior = .mutedWhenTapped

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else { return nil }

        guard let tapUID = tapUID(tapID) else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynamic Island Mixer",
            kAudioAggregateDeviceUIDKey: "dev.local.dynamicisland.mixer.\(tapUID)",
            // Private: it must not appear in Sound settings as a device the
            // user could pick by accident.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var aggregateID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0
        else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let engine = Engine()
        engine.tap = tapID
        engine.aggregate = aggregateID
        engine.outputUID = outputUID
        engine.gain.withLock { $0 = gain }

        // The callback runs on CoreAudio's real-time thread. It reads the lock
        // and copies samples - no allocation, nothing that can block.
        let lock = engine.gain
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in
            let level = lock.withLock { $0 }
            let input = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            let channels = min(input.count, output.count)
            for channel in 0 ..< channels {
                let source = input[channel]
                let destination = output[channel]
                guard let from = source.mData, let to = destination.mData else { continue }
                let bytes = min(source.mDataByteSize, destination.mDataByteSize)
                let frames = Int(bytes) / MemoryLayout<Float>.size
                let fromSamples = from.assumingMemoryBound(to: Float.self)
                let toSamples = to.assumingMemoryBound(to: Float.self)
                for frame in 0 ..< frames {
                    toSamples[frame] = fromSamples[frame] * level
                }
                // Anything the tap did not fill must be silence, or the previous
                // buffer's contents are played again as a click.
                if destination.mDataByteSize > bytes {
                    memset(to.advanced(by: Int(bytes)), 0,
                           Int(destination.mDataByteSize - bytes))
                }
            }
        }

        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        engine.procID = procID

        guard AudioDeviceStart(aggregateID, procID) == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        return engine
    }

    /// Order matters: stop the callback, then drop it, then the device, then the
    /// tap. Destroying a tap that a running aggregate still references leaves
    /// the app silent until the next login.
    private nonisolated static func destroy(_ engine: Engine) {
        if let procID = engine.procID {
            AudioDeviceStop(engine.aggregate, procID)
            AudioDeviceDestroyIOProcID(engine.aggregate, procID)
        }
        if engine.aggregate != 0 { AudioHardwareDestroyAggregateDevice(engine.aggregate) }
        if engine.tap != 0 { AudioHardwareDestroyProcessTap(engine.tap) }
    }

    private func teardown(_ pid: pid_t) {
        guard let engine = engines.removeValue(forKey: pid) else { return }
        Self.destroy(engine)
    }

    /// Called when the module is switched off, and on quit.
    func stopAll() {
        for pid in engines.keys { teardown(pid) }
    }

    // MARK: - CoreAudio helpers

    private nonisolated static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func pid(_ object: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return value
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0
        else { return nil }

        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid as String
    }

    private nonisolated static func tapUID(_ tap: AudioObjectID) -> String? {
        var addr = address(kAudioTapPropertyUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }
}
