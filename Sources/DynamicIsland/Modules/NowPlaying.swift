import AppKit
import Foundation

/// Now Playing via the vendored mediaremote-adapter.
///
/// The helper is a perl process, so it is spawned only while the default output
/// device is actually running audio and torn down after a grace period of
/// silence. Idle means zero helper processes, which is the whole point.
@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artwork: NSImage?
    private(set) var playing = false
    private(set) var bundleID = ""
    private(set) var duration: Double = 0
    /// Playback position at `positionStamp`. Live position is derived from these
    /// two, never from a ticking timer.
    private(set) var position: Double = 0
    private(set) var positionStamp = Date()
    private(set) var playbackRate: Double = 0

    var hasTrack: Bool { !title.isEmpty }

    /// Fallback subtitle when a source reports no artist - browser audio usually
    /// does not. Showing the app beats showing an empty line.
    var sourceName: String {
        guard !bundleID.isEmpty else { return "" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    /// Current position without polling the helper.
    var livePosition: Double {
        guard playing, playbackRate > 0 else { return position }
        return min(position + Date().timeIntervalSince(positionStamp) * playbackRate, duration)
    }

    private var task: Process?
    private var idleWork: DispatchWorkItem?
    private var buffer = Data()

    /// Consecutive unexpected helper exits. Drives the retry backoff and the
    /// health readout in Settings.
    private(set) var failures = 0
    private var restartWork: DispatchWorkItem?
    private var orphansCleared = false

    /// When we last asked for the previous track, and whether we have already
    /// asked a second time. See `retryPreviousIfRestarted`.
    private var previousSentAt: Date?
    private var previousRetried = false

    /// What Settings shows about the Now Playing helper.
    var health: String {
        if !Settings.shared.nowPlaying { return "Disabled" }
        if failures >= 5 { return "Not working - the adapter may be broken by a macOS update" }
        if failures > 0 { return "Retrying (\(failures))" }
        return task == nil ? "Idle" : "Running"
    }

    private init() {}

    /// Called at launch and whenever the set of processes outputting audio
    /// changes - something new started, so Now Playing is worth checking.
    ///
    /// We cannot gate purely on audio output: Chrome holds an output stream open
    /// permanently, so "something is outputting" is true forever on most Macs.
    /// Instead we spawn on a change and let the helper's own `playing` report
    /// decide when to shut back down.
    func nudge() {
        guard Settings.shared.nowPlaying else { stop(); return }
        start()
        scheduleIdleCheck()
    }

    /// Shut the helper down only when there is no track at all.
    ///
    /// Paused is not idle: a paused track still has to show in the island, and
    /// killing the helper after five minutes of pause meant Now Playing quietly
    /// emptied itself while the music was merely stopped.
    private func scheduleIdleCheck() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if hasTrack {
                scheduleIdleCheck()
            } else {
                stop()
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    /// Waking from sleep tears down the helper's connection to mediaremoted, and
    /// closing the lid counts as sleep. Without this the island came back from a
    /// lid close with Now Playing permanently blank.
    func watchWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NowPlaying.shared.restartAfterWake()
            }
        }
    }

    private func restartAfterWake() {
        guard Settings.shared.nowPlaying else { return }
        failures = 0
        stop()
        // Give mediaremoted a moment to come back before reconnecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.nudge() }
    }

    /// Kills helpers left behind by a previous instance.
    ///
    /// A crash or a force quit does not take the helper with it: the child is
    /// reparented to launchd and carries on streaming forever. Measured during
    /// development - three orphans accumulated across restarts, all of them
    /// still parsing media updates for an app that no longer existed. Every
    /// launch clears any it finds before starting its own.
    ///
    /// Once per launch, not once per start: the pattern also matches this
    /// instance's own `send` and `seek` runs, and a restart that killed one of
    /// those dropped the press or reported a refused seek.
    private func killOrphans() {
        guard !orphansCleared else { return }
        orphansCleared = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Match the script path, not "perl" - the user may be running their own.
        process.arguments = ["-f", "mediaremote-adapter.pl"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func start() {
        guard task == nil, Settings.shared.nowPlaying else { return }
        killOrphans()
        guard let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let framework = Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework")
        else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // Default (diff) mode: artwork only arrives when the track actually
        // changes, instead of a few hundred KB of base64 on every update.
        // `--micros` for the one key that has no other usable form: the epoch
        // time the player measured the elapsed time at. See `apply`.
        process.arguments = [script, framework, "stream", "--debounce=250", "--micros"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // Empty means EOF: the helper is gone. Left installed, the handler
            // is called straight back with nothing, forever - a core spinning
            // on a dead pipe after every helper crash.
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] exited in
            Task { @MainActor in self?.helperExited(exited) }
        }

        do { try process.run() } catch { failures += 1; return }
        task = process
        // `failures` is not reset here. A helper that launches and dies at once -
        // the adapter broken by a macOS update - would otherwise read as healthy
        // on every launch, and the backoff would sit at two seconds forever. It
        // is reset by the first line the helper actually delivers.
    }

    /// The helper dying used to leave Now Playing frozen until the audio device
    /// set happened to change - which could be never.
    ///
    /// Only the current helper counts. One that was stopped, or replaced, can
    /// report its exit after its successor has started - and clearing `task` then
    /// orphaned the live helper, so the next start killed it and the cycle
    /// repeated every couple of seconds.
    private func helperExited(_ process: Process) {
        guard process === task else { return }
        task = nil
        guard Settings.shared.nowPlaying else { return }

        failures += 1
        guard failures < 8 else { return }   // give up rather than spin
        let delay = min(pow(2.0, Double(failures)), 60)
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        idleWork?.cancel()
        idleWork = nil
        restartWork?.cancel()
        restartWork = nil
        guard let task else { return }
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        task.terminate()
        self.task = nil
        clear()
    }

    private func clear() {
        title = ""; artist = ""; album = ""; artwork = nil; bundleID = ""
        playing = false; duration = 0; position = 0; playbackRate = 0
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        // The adapter emits one JSON object per line.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            failures = 0
            apply(object)
        }
        // A wedged helper must not grow the buffer without bound.
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    /// Jump to a position, in seconds.
    ///
    /// Two routes, because MediaRemote's own seek is not universal: several
    /// players refuse it. Measured against Spotify - the adapter exits 1 with
    /// "Failed to seek to 30000000" and the track does not move - and the old
    /// code sent that into a `try?` with both pipes at `nullDevice`, so the bar
    /// jumped to where you pressed, nothing happened, and the next update from
    /// the player snapped it back. That is the whole "timeline does not work".
    ///
    /// Spotify and Music both take `set player position to`, so a refused seek
    /// falls through to that. Anything else - browser audio, mostly - genuinely
    /// cannot be seeked, and says so instead of pretending.
    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        let previous = position
        let previousStamp = positionStamp
        // Optimistic, so the bar lands under the finger rather than waiting a
        // round trip for the player to report back.
        position = clamped
        positionStamp = Date()

        let script = Self.seekScript(bundleID: bundleID, seconds: clamped)
        Self.runSeek(microseconds: Int(clamped * 1_000_000), fallback: script) { [weak self] ok in
            guard let self, !ok else { return }
            // Put the bar back where the audio actually is. A control that sits
            // where you left it while the sound plays on somewhere else is worse
            // than one that admits it did nothing.
            position = previous
            positionStamp = previousStamp
            // A player with a script route has only one realistic way to fail
            // here, and it is the Automation prompt - either unanswered or
            // declined. One that has no script route cannot be seeked at all,
            // and saying "allow Automation" there would send the user off to
            // flip a switch that changes nothing.
            guard script != nil else {
                HUD.shared.show(
                    .utility(symbol: "forward.end.alt.fill",
                             title: "Cannot seek",
                             detail: sourceName.isEmpty ? "Player refused" : "\(sourceName) refused it"),
                    for: 2.6
                )
                return
            }
            HUD.shared.show(
                .utility(symbol: "lock.slash",
                         title: "Automation is off",
                         detail: Permissions.detail(for: sourceName.isEmpty ? "the player" : sourceName)),
                for: 3.4
            )
            Permissions.open("Privacy_Automation")
        }
    }

    /// The scripted route for the players that have one. Both use the same verb.
    private static func seekScript(bundleID: String, seconds: Double) -> String? {
        let application: String
        switch bundleID {
        case "com.spotify.client": application = "Spotify"
        case "com.apple.Music", "com.apple.iTunes": application = "Music"
        default: return nil
        }
        return "tell application \"\(application)\" to set player position to \(Int(seconds))"
    }

    /// Runs the adapter, and only on a non-zero exit tries the script.
    ///
    /// Off the main thread: both are process launches, and the adapter waits on
    /// the player. `run` deliberately never waits, which is right for fire-and-
    /// forget commands and wrong here - the exit status *is* the answer.
    private static func runSeek(
        microseconds: Int, fallback: String?, then finish: @escaping @MainActor (Bool) -> Void
    ) {
        guard let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let framework = Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework")
        else { DispatchQueue.main.async { MainActor.assumeIsolated { finish(false) } }; return }

        DispatchQueue.global(qos: .userInitiated).async {
            var ok = launch("/usr/bin/perl", [script, framework, "seek", String(microseconds)])
            if !ok, let fallback {
                ok = launch("/usr/bin/osascript", ["-e", fallback])
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(ok) } }
        }
    }

    /// True only when the process ran *and* exited cleanly. A process that never
    /// launched reports a status of 0, so the launch has to be checked first.
    private nonisolated static func launch(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Bring the app the audio is coming from to the front.
    func focusSource() {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Folds one streamed update into the current state.
    ///
    /// The stream is a *diff*: only changed keys are sent, and the adapter
    /// documents that "when a key is not present anymore, it's set to `null`
    /// in the payload and its previous value should be removed". Only `title`
    /// was ever checked for that null, so every other field kept a value the
    /// player had already dropped.
    private func apply(_ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? json
        let previousTitle = title

        // Not every message is a diff. Measured: the first one and the one at
        // every track change are full payloads (`diff: false`), and in a full
        // payload a missing key means gone, not unchanged.
        if json["diff"] as? Bool == false { clear() }

        // Absent means unchanged; null means gone.
        func read(_ key: String, into current: inout String) {
            if let value = payload[key] as? String { current = value }
            else if payload[key] is NSNull { current = "" }
        }
        func read(_ key: String, into current: inout Double, scale: Double = 1) {
            if let value = (payload[key] as? NSNumber)?.doubleValue { current = value / scale }
            else if payload[key] is NSNull { current = 0 }
        }

        read("title", into: &title)
        read("artist", into: &artist)
        read("album", into: &album)
        read("bundleIdentifier", into: &bundleID)
        read("durationMicros", into: &duration, scale: 1_000_000)
        read("playbackRate", into: &playbackRate)

        if let value = payload["playing"] as? Bool { playing = value }
        else if payload["playing"] is NSNull { playing = false }
        // Stamped with the moment the player measured it, not the moment the
        // line reached us. The two are a debounce and a pipe apart - a quarter
        // of a second or more - and stamping on arrival put every position that
        // far behind the music, which the lyrics made easy to hear.
        if let micros = (payload["elapsedTimeMicros"] as? NSNumber)?.doubleValue {
            position = micros / 1_000_000
            positionStamp = (payload["timestampEpochMicros"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1_000_000) } ?? Date()
        } else if payload["elapsedTimeMicros"] is NSNull {
            position = 0
            positionStamp = Date()
        }

        // The title alone says the track changed. Not `contentItemIdentifier`:
        // measured on Spotify, a skip delivers the new track, then its cover,
        // then a second identifier for the same song half a second later - read
        // as another track change, that wiped the cover that had just landed
        // (the adapter never sends an unchanged cover again) and peeked twice.
        // Not title *and* artist either: those two can arrive in separate
        // diffs, with the same double change.
        let newTrack = title != previousTitle

        // Artwork is the one field that cannot be treated as "absent means
        // unchanged", because the adapter says it "often takes a bit of time to
        // load and may not appear in the output in all cases" - it arrives in a
        // *later* message than the title it belongs to. Keeping the old picture
        // until then is exactly why the cover ran a track behind the song.
        //
        // So on a new track the old cover goes immediately and the panel shows
        // the source app's icon until the real one lands, which is a moment of
        // honesty rather than a minute of being wrong.
        if let encoded = payload["artworkData"] as? String {
            // A picture that will not decode is not a picture. Keeping the last
            // one would put the wrong cover on this track either way.
            artwork = Data(base64Encoded: encoded)
                .flatMap(NSImage.init(data:))
                .map { Self.downsampled($0) }
        } else if payload["artworkData"] is NSNull || newTrack {
            artwork = nil
        }

        // No `clear()` on a null title inside a diff. That wiped `playing`,
        // `playbackRate` and `duration` locally while the adapter still held
        // them as unchanged and so never sent them again - leaving a player
        // that read as paused while the music played, whose play button, being
        // a toggle, then really did pause it. Each removed key arrives as its
        // own null, which the reads above already handle.

        // One request per track, on the change itself - never on a progress
        // update, of which there are many.
        if newTrack { Lyrics.shared.refresh() }

        retryPreviousIfRestarted(trackChanged: newTrack)

        // Peek only on a real track change, not on every progress update.
        if Settings.shared.sneakPeek, !title.isEmpty, newTrack, playing {
            HUD.shared.show(
                .track(title: title, subtitle: artist.isEmpty ? sourceName : artist, art: artwork),
                for: 2.4
            )
        }
    }

    /// Album art arrives at full source resolution - often 1500px square. The
    /// island never shows it larger than 62pt, so keeping the original just
    /// holds megabytes of pixels we cannot see.
    private static func downsampled(_ image: NSImage, to side: CGFloat = 160) -> NSImage {
        let source = image.size
        guard source.width > side || source.height > side else { return image }
        let scale = min(side / source.width, side / source.height)
        let target = NSSize(width: source.width * scale, height: source.height * scale)

        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        output.unlockFocus()
        return output
    }

    // MARK: - Commands

    /// MRCommand ids used by the adapter's `send`.
    enum Command: Int { case togglePlayPause = 2, next = 4, previous = 5 }

    // The adapter reports no shuffle or repeat state, only accepts commands for
    // them. Tracking a local flag would light the button up wrongly the moment
    // shuffle was changed in the player itself, so these are deliberately
    // stateless: they send, they do not claim to know.
    private(set) var shuffling = false
    private(set) var repeating = false

    func toggleShuffle() {
        shuffling.toggle()
        run(["shuffle", shuffling ? "2" : "1"])
    }

    func toggleRepeat() {
        repeating.toggle()
        run(["repeat", repeating ? "3" : "1"])
    }

    /// Icon of the app the audio is coming from, shown as a badge on the art so
    /// the source is obvious without a label.
    var sourceIcon: NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func send(_ command: Command) {
        switch command {
        case .previous:
            previousSentAt = Date()
            previousRetried = false
        case .next, .togglePlayPause:
            previousSentAt = nil
        }
        run(["send", String(command.rawValue)])
    }

    /// Asks a second time when Previous only restarted the current track.
    ///
    /// Players answer Previous in one of two ways, and which one depends on how
    /// far into the track you are: Spotify and Music both restart the current
    /// track once you are a few seconds in, and only go back when you are near
    /// the beginning. Pressing back and getting the same song from the top
    /// again and again is that rule, not a failure to send the command.
    ///
    /// The restart is unmistakable and needs no guessing at player state: the
    /// track is the same one and the position has gone back to zero. That is
    /// the case where asking once more is what the user meant by "back".
    ///
    /// ponytail: one retry, and only ever one. A loop here would walk backwards
    /// through the queue for as long as the player kept restarting.
    private func retryPreviousIfRestarted(trackChanged: Bool) {
        guard let previousSentAt else { return }
        // It went back properly; nothing more to do.
        if trackChanged {
            self.previousSentAt = nil
            return
        }
        guard !previousRetried,
              Date().timeIntervalSince(previousSentAt) < 2,
              position < 2
        else { return }
        previousRetried = true
        run(["send", String(Command.previous.rawValue)])
    }

    /// Commands go out one at a time.
    ///
    /// Every command is a perl process that has to start an interpreter and
    /// load the framework before it can say anything - a tenth of a second or
    /// so. Fired off concurrently, five quick presses of skip meant five
    /// interpreters starting at once and each sending its command whenever it
    /// happened to get there, in whatever order they finished booting. A
    /// player handed overlapping transport commands out of order is a player
    /// that ends up somewhere nobody asked for.
    private static let commands = DispatchQueue(label: "dev.local.dynamicisland.media-commands")

    private func run(_ arguments: [String]) {
        guard let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let framework = Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework")
        else { return }
        Self.commands.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [script, framework] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // A command that hung would hold this queue for good and every
            // press after it would go nowhere - the transport would simply
            // stop working until the app was restarted. Waiting with a limit
            // costs nothing and takes that away.
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            guard (try? process.run()) != nil else { return }
            // Off the main thread, so waiting costs nothing that anybody sees.
            // The next command must not go out until this one has been
            // delivered, which is the whole reason for the queue.
            if finished.wait(timeout: .now() + 5) == .timedOut { process.terminate() }
        }
    }
}
