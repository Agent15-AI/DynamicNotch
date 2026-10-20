import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// The sound graph: what is playing, as 24 bars of frequency.
///
/// macOS hands an app no audio but its own, so this listens the way the mixer
/// does - a process tap and a private aggregate device - with two differences:
/// the tap is global, and it is *unmuted*. Nothing is re-rendered and nothing
/// you hear changes; the samples are only read.
///
/// That listener is the cost, so it exists only while someone can see the
/// bars: the player on screen and the music playing. Closing the island,
/// switching tabs or pausing tears the whole thing down. At rest there is no
/// tap, no device and no callback - the closed island keeps its static bars.
///
/// The audio thread does the arithmetic: one 1024-point FFT about twenty times a
/// second, into buffers allocated once, never on the main thread. The view
/// copies 24 numbers out per frame and draws them as 24 capsules.
@MainActor
@Observable
final class Spectrum {
    static let shared = Spectrum()
    nonisolated static let bands = 24

    /// Written by the audio thread, read by the view.
    @ObservationIgnored nonisolated let levels = Levels(count: Spectrum.bands)
    /// True while the listener is running, so the view can stop redrawing.
    private(set) var running = false

    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var building = false

    private init() {}

    /// Called by each view that shows the bars, paired with `release`.
    func hold() {
        holders += 1
        if holders == 1 { start() }
    }

    func release() {
        holders = max(0, holders - 1)
        if holders == 0 { stop() }
    }

    private func start() {
        let audio = AudioMonitor.shared
        guard engine == nil, !building,
              let output = audio.outputs.first(where: { $0.id == audio.currentOutput })?.uid
        else { return }
        building = true
        let levels = levels
        // Off the main thread for the mixer's reason: creating a tap raises the
        // System Audio Recording prompt the first time, and that blocks.
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = Self.build(outputUID: output, levels: levels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.building = false
                    guard let engine else { return }
                    guard self.holders > 0 else { Self.destroy(engine); return }
                    self.engine = engine
                    self.running = true
                    self.checkForSilence(engine)
                }
            }
        }
    }

    /// One rebuild of a listener that has heard nothing at all.
    ///
    /// A tap made while the System Audio Recording prompt is still unanswered
    /// is fed zeros for the rest of its life, and saying Allow does not change
    /// that - only a new tap hears anything. The first open is exactly that
    /// tap, so the graph sat flat until the island was closed and reopened.
    /// Two seconds of nothing with music playing is the tell; once per opening,
    /// so a track with a silent intro costs one rebuild and no more.
    private func checkForSilence(_ engine: Engine) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.engine === engine, !self.levels.heard, !self.retried else { return }
            self.retried = true
            Self.destroy(engine)
            self.engine = nil
            self.start()
        }
    }

    @ObservationIgnored private var retried = false

    private func stop() {
        if let engine { Self.destroy(engine) }
        engine = nil
        retried = false
        running = false
        levels.reset()
    }

    // MARK: - The listener

    private final class Engine: @unchecked Sendable {
        var tap: AudioObjectID = 0
        var aggregate: AudioObjectID = 0
        var procID: AudioDeviceIOProcID?
        var analyser: Analyser?
    }

    private nonisolated static func build(outputUID: String, levels: Levels) -> Engine? {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Dynamic Island Sound Graph"
        description.isPrivate = true
        // Unmuted: the music keeps playing exactly as it was. This only reads.
        description.muteBehavior = .unmuted

        let engine = Engine()
        guard AudioHardwareCreateProcessTap(description, &engine.tap) == noErr, engine.tap != 0 else { return nil }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = address(kAudioTapPropertyFormat)
        guard let tapUID = string(engine.tap, kAudioTapPropertyUID),
              AudioObjectGetPropertyData(engine.tap, &formatAddress, 0, nil, &formatSize, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let analyser = Analyser(sampleRate: format.mSampleRate, levels: levels)
        else { destroy(engine); return nil }
        engine.analyser = analyser

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynamic Island Sound Graph",
            kAudioAggregateDeviceUIDKey: "dev.local.dynamicisland.spectrum.\(tapUID)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &engine.aggregate) == noErr,
              engine.aggregate != 0
        else { destroy(engine); return nil }

        // Reads the input and writes nothing, so the output stays silent and
        // what you hear is untouched. No allocation in here - see `Analyser`.
        guard AudioDeviceCreateIOProcIDWithBlock(&engine.procID, engine.aggregate, nil, { _, input, _, _, _ in
            analyser.consume(input)
        }) == noErr, let procID = engine.procID,
              AudioDeviceStart(engine.aggregate, procID) == noErr
        else { destroy(engine); return nil }
        return engine
    }

    /// Stop the callback, drop it, then the device, then the tap - the order the
    /// mixer learned.
    private nonisolated static func destroy(_ engine: Engine) {
        if let procID = engine.procID {
            AudioDeviceStop(engine.aggregate, procID)
            AudioDeviceDestroyIOProcID(engine.aggregate, procID)
        }
        if engine.aggregate != 0 { AudioHardwareDestroyAggregateDevice(engine.aggregate) }
        if engine.tap != 0 { AudioHardwareDestroyProcessTap(engine.tap) }
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

// MARK: - Levels

/// 24 numbers handed from the audio thread to the main one.
///
/// A pointer and a lock rather than an array: an array the reader still holds
/// would make the writer copy it, and a copy is an allocation on a real-time
/// thread.
final class Levels: @unchecked Sendable {
    let count: Int
    private let lock = OSAllocatedUnfairLock()
    private let values: UnsafeMutablePointer<Float>

    init(count: Int) {
        self.count = count
        values = .allocate(capacity: count)
        values.initialize(repeating: 0, count: count)
    }

    deinit { values.deallocate() }

    /// Whether any bar has risen since the last reset. See `checkForSilence`.
    private var signal = false

    func store(_ source: UnsafePointer<Float>) {
        lock.withLockUnchecked {
            values.update(from: source, count: count)
            if !signal { signal = (0 ..< count).contains { source[$0] > 0 } }
        }
    }

    func read() -> [Float] {
        lock.withLockUnchecked { Array(UnsafeBufferPointer(start: values, count: count)) }
    }

    var heard: Bool { lock.withLockUnchecked { signal } }

    func reset() {
        lock.withLockUnchecked {
            values.update(repeating: 0, count: count)
            signal = false
        }
    }
}

// MARK: - Analysis

/// Samples in, bar heights out. Runs on CoreAudio's real-time thread, so every
/// buffer is allocated here, once.
private final class Analyser: @unchecked Sendable {
    private static let size = 1024
    private let levels: Levels
    /// Samples between analyses: a twentieth of a second, which is as fast as
    /// the bars are drawn. Analysing every callback would triple the work for
    /// frames nobody sees.
    private let hop: Int
    private let setup: vDSP_DFT_Setup
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: Analyser.size)
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: Analyser.size)
    private let even = UnsafeMutablePointer<Float>.allocate(capacity: Analyser.size / 2)
    private let odd = UnsafeMutablePointer<Float>.allocate(capacity: Analyser.size / 2)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: Analyser.size / 2)
    private let imaginary = UnsafeMutablePointer<Float>.allocate(capacity: Analyser.size / 2)
    private let smoothed = UnsafeMutablePointer<Float>.allocate(capacity: Spectrum.bands)
    /// Each bar's FFT bins, `lower ..< upper`. Log-spaced from 50 Hz to 14 kHz,
    /// the way hearing spaces pitch: a linear split gives the whole left half of
    /// the graph to the top octave.
    private let lower = UnsafeMutablePointer<Int>.allocate(capacity: Spectrum.bands)
    private let upper = UnsafeMutablePointer<Int>.allocate(capacity: Spectrum.bands)
    private var head = 0
    private var pending = 0

    init?(sampleRate: Double, levels: Levels) {
        guard sampleRate > 0,
              let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)
        else { return nil }
        self.setup = setup
        self.levels = levels
        hop = max(256, Int(sampleRate / 20))
        ring.initialize(repeating: 0, count: Self.size)
        vDSP_hann_window(window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        smoothed.initialize(repeating: 0, count: Spectrum.bands)

        let binWidth = sampleRate / Double(Self.size)
        let bins = Self.size / 2
        var previous = 1
        for band in 0 ..< Spectrum.bands {
            let edge = 50 * pow(14_000 / 50, Double(band + 1) / Double(Spectrum.bands))
            let top = min(max(Int((edge / binWidth).rounded()), previous + 1), bins)
            lower[band] = min(previous, bins - 1)
            upper[band] = max(top, lower[band] + 1)
            previous = upper[band]
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
        for pointer in [ring, window, even, odd, real, imaginary, smoothed] { pointer.deallocate() }
        lower.deallocate()
        upper.deallocate()
    }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count > 0, let data = buffers[0].mData else { return }
        // Interleaved stereo in one buffer, as the tap delivers it; a split
        // layout puts the left channel here, which is enough to draw.
        let channels = max(Int(buffers[0].mNumberChannels), 1)
        let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let samples = data.assumingMemoryBound(to: Float.self)
        let mask = Self.size - 1
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channels { sum += samples[frame * channels + channel] }
            ring[head] = sum / Float(channels)
            head = (head + 1) & mask
        }
        pending += frames
        guard pending >= hop else { return }
        pending = 0
        analyse()
    }

    private func analyse() {
        let size = Self.size
        let mask = size - 1
        // Oldest to newest, windowed, split into the even/odd halves the real
        // transform takes as its input.
        for index in 0 ..< size {
            let sample = ring[(head + index) & mask] * window[index]
            if index & 1 == 0 { even[index >> 1] = sample } else { odd[index >> 1] = sample }
        }
        vDSP_DFT_Execute(setup, even, odd, real, imaginary)

        // A full-scale sine reads 1: the real transform comes back at twice the
        // textbook N/2, and the Hann window halves it again.
        let scale = Float(2) / Float(size)
        for band in 0 ..< Spectrum.bands {
            var power: Float = 0
            for bin in lower[band] ..< upper[band] {
                power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
            }
            // Energy summed across the band, so bands that span more bins are
            // not taller just for being wider in hertz than in pitch.
            let decibels = 20 * log10(max(power.squareRoot() * scale, 1e-7))
            // -50 dB to -4 dB per band: quiet passages near the floor, a mastered
            // chorus most of the way up, a kick drum at the top.
            let target = min(max((decibels + 50) / 46, 0), 1)
            // Up fast, down slowly: a bar that drops as quickly as it rises
            // flickers instead of reading as a level.
            let current = smoothed[band]
            smoothed[band] = target > current ? current + (target - current) * 0.65 : current * 0.8 + target * 0.2
        }
        levels.store(smoothed)
    }
}
