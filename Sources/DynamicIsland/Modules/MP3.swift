import AudioToolbox
import Foundation
import Shine

/// MP3 encoding, because macOS has none.
///
/// AudioToolbox decodes MP3 and refuses to write it - `afconvert -f MPG3` answers
/// `fmt?`, and every AVFoundation export preset that mentions audio produces AAC.
/// So the one format everything on earth can play is the one format a Mac cannot
/// make without help. `Sources/Shine` is that help: 2,800 lines of C, no
/// dependencies, vendored so nothing has to be installed.
///
/// Decoding is the system's job. `ExtAudioFile` reads anything macOS knows - m4a,
/// aac, wav, aiff, flac, opus in a Core Media container - and converts it to the
/// 16-bit interleaved samples the encoder wants, resampling on the way. That is
/// why there is no format handling here.
enum MP3 {
    enum Failure: LocalizedError {
        case unreadable(OSStatus)
        case unsupported
        case encoder
        case write(Error)

        var errorDescription: String? {
            switch self {
            case .unreadable: "Could not read that audio"
            case .unsupported: "That sample rate and bitrate pair is not MP3"
            case .encoder: "The encoder would not start"
            case .write(let error): error.localizedDescription
            }
        }
    }

    /// 44.1 kHz, which every MP3 decoder supports and every music source is
    /// already at or near. Resampling is `ExtAudioFile`'s problem, not ours.
    private static let sampleRate: Double = 44_100

    /// Encodes any audio file macOS can decode into MP3.
    ///
    /// `progress` is called on whatever thread this runs on, from 0 to 1. Call it
    /// off the main thread: a three-minute track takes a couple of seconds.
    static func encode(
        _ source: URL,
        to destination: URL,
        bitrate: Int = 192,
        progress: ((Double) -> Void)? = nil
    ) throws {
        var file: ExtAudioFileRef?
        let opened = ExtAudioFileOpenURL(source as CFURL, &file)
        guard opened == noErr, let file else { throw Failure.unreadable(opened) }
        defer { ExtAudioFileDispose(file) }

        // Mono stays mono - doubling it would double the bytes for no sound.
        var sourceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let read = ExtAudioFileGetProperty(
            file, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat
        )
        guard read == noErr else { throw Failure.unreadable(read) }
        let channels = sourceFormat.mChannelsPerFrame == 1 ? UInt32(1) : UInt32(2)

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let set = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client
        )
        guard set == noErr else { throw Failure.unreadable(set) }

        // Only for the progress fraction. A file that does not know its own
        // length still encodes; it just reports nothing on the way.
        var totalFrames: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &totalFrames)
        // Frames are counted at the source rate; the client reads them at 44.1k.
        let expected = sourceFormat.mSampleRate > 0
            ? Double(totalFrames) * sampleRate / sourceFormat.mSampleRate
            : 0

        var config = shine_config_t()
        shine_set_config_mpeg_defaults(&config.mpeg)
        config.wave.channels = channels == 1 ? PCM_MONO : PCM_STEREO
        config.wave.samplerate = Int32(sampleRate)
        config.mpeg.mode = channels == 1 ? MONO : STEREO
        config.mpeg.bitr = Int32(bitrate)
        guard shine_check_config(config.wave.samplerate, config.mpeg.bitr) >= 0 else {
            throw Failure.unsupported
        }
        guard let encoder = shine_initialise(&config) else { throw Failure.encoder }
        defer { shine_close(encoder) }

        let perPass = Int(shine_samples_per_pass(encoder))
        var samples = [Int16](repeating: 0, count: perPass * Int(channels))
        var mp3 = Data()
        var encodedFrames = 0.0

        while true {
            // Zeroed every pass: a short last read must be padded with silence
            // rather than with the previous pass's samples.
            for index in samples.indices { samples[index] = 0 }
            var frames = UInt32(perPass)
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(samples.count * 2),
                    mData: nil
                )
            )
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                buffers.mBuffers.mData = raw.baseAddress
                return ExtAudioFileRead(file, &frames, &buffers)
            }
            guard status == noErr else { throw Failure.unreadable(status) }
            guard frames > 0 else { break }

            var written: Int32 = 0
            let chunk = samples.withUnsafeMutableBufferPointer { buffer in
                shine_encode_buffer_interleaved(encoder, buffer.baseAddress, &written)
            }
            if let chunk, written > 0 {
                mp3.append(chunk, count: Int(written))
            }
            encodedFrames += Double(frames)
            if let progress, expected > 0 {
                progress(min(encodedFrames / expected, 1))
            }
        }

        var flushed: Int32 = 0
        if let tail = shine_flush(encoder, &flushed), flushed > 0 {
            mp3.append(tail, count: Int(flushed))
        }

        do {
            try mp3.write(to: destination, options: .atomic)
        } catch {
            throw Failure.write(error)
        }
        progress?(1)
    }
}
