import CoreAudio
import Foundation

/// Play to several outputs at once - the laptop speakers and a Bluetooth speaker,
/// or two AirPlay receivers.
///
/// macOS can do this, but only from Audio MIDI Setup: you build a "Multi-Output
/// Device" by hand, remember to point Sound at it, and remember to point Sound
/// back afterwards. This is the same CoreAudio object, created from a checklist in
/// the output menu and destroyed again when you switch it off.
///
/// ponytail: a stacked aggregate device *is* a multi-output device - the same
/// public API `VolumeMixer` already builds its per-app engines with. Nothing here
/// renders audio: CoreAudio copies the stream to each sub-device itself, so the
/// cost while this is on is the extra device, not a callback of ours.
///
/// Session-only, deliberately. A restored multi-output would have to recreate a
/// CoreAudio device at login and repoint the system's sound at it before the user
/// asked for anything, which is exactly the kind of thing that leaves a Mac
/// silent for reasons nobody can find.
@MainActor
@Observable
final class MultiOutput {
    static let shared = MultiOutput()

    /// UIDs being played to, in the order they were added. Empty when off.
    private(set) var uids: [String] = []

    /// The device this created, or 0.
    private var device: AudioObjectID = 0
    /// Where the sound was going before, so switching off puts it back.
    private var previous: AudioDeviceID = 0

    var active: Bool { device != 0 }

    private static let uid = "dev.local.dynamicisland.multioutput"

    private init() {}

    func contains(_ output: AudioMonitor.Output) -> Bool { uids.contains(output.uid) }

    /// Adds or removes one output. The device is rebuilt rather than edited: an
    /// aggregate's sub-device list is fixed once CoreAudio has it.
    func toggle(_ output: AudioMonitor.Output) {
        // Our own device in the list would be a loop.
        guard output.uid != Self.uid else { return }
        // Recorded once, on the way out of "off": where the sound was before any
        // of this started is the only thing worth restoring, and it has to be
        // read before the first build moves it.
        if uids.isEmpty { previous = AudioMonitor.shared.currentOutput }
        if uids.contains(output.uid) {
            uids.removeAll { $0 == output.uid }
        } else {
            uids.append(output.uid)
        }
        rebuild()
    }

    /// Back to one device, with the sound where it started.
    func stop() {
        uids = []
        rebuild()
    }

    private func rebuild() {
        destroy()

        // One device is not a multi-output: hand it straight to the system and
        // let the plain picker own it. None left means back where we came from -
        // the aggregate has just been destroyed, and a system whose default
        // output no longer exists is a silent Mac until something reselects.
        guard uids.count > 1 else {
            if let single = uids.first,
               let match = AudioMonitor.shared.outputs.first(where: { $0.uid == single }) {
                AudioMonitor.shared.selectOutput(match.id)
            } else if previous != 0 {
                AudioMonitor.shared.selectOutput(previous)
                previous = 0
            }
            return
        }

        guard let main = uids.first else { return }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynamic Island Multi-Output",
            kAudioAggregateDeviceUIDKey: Self.uid,
            // Private, for the reason the mixer's aggregates are: it must not
            // show up in Sound settings as a device to pick by accident, and it
            // stops existing the moment this is switched off.
            kAudioAggregateDeviceIsPrivateKey: true,
            // Stacked is what makes it a multi-output rather than a device with
            // several separate streams.
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: main,
            kAudioAggregateDeviceSubDeviceListKey: uids.map { uid in
                [
                    kAudioSubDeviceUIDKey: uid,
                    // The clock master keeps its own timing; everything else is
                    // resampled to it, or the second speaker drifts audibly out
                    // of step within a minute.
                    kAudioSubDeviceDriftCompensationKey: uid == main ? 0 : 1,
                ]
            },
        ]

        var created: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &created) == noErr,
              created != 0
        else {
            // Says so rather than leaving a checklist that silently did nothing,
            // and puts the sound back - the device it was on may have been the
            // aggregate this call just destroyed.
            uids = []
            if previous != 0 {
                AudioMonitor.shared.selectOutput(previous)
                previous = 0
            }
            HUD.shared.show(
                .utility(symbol: "speaker.slash.fill", title: "Could not combine",
                         detail: "CoreAudio refused those devices"),
                for: 2.8
            )
            return
        }
        device = created
        AudioMonitor.shared.selectOutput(created)
    }

    /// Called on quit as well. A leaked aggregate device outlives the process and
    /// leaves the system's sound pointed at something that no longer works.
    func destroy() {
        guard device != 0 else { return }
        let dying = device
        device = 0
        AudioHardwareDestroyAggregateDevice(dying)
    }

    /// Puts the sound back where it was and takes the device with it.
    func stopAll() {
        let restore = previous
        destroy()
        uids = []
        previous = 0
        guard restore != 0 else { return }
        AudioMonitor.shared.selectOutput(restore)
    }
}
