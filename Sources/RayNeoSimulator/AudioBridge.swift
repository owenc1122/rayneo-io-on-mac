import AVFoundation

/// Host side of the HiFi4 audio DSP stand-in (platform/peripherals/BES1700_HiFi4.cs).
/// Microphone: the default input is converted to s16le 16 kHz mono and appended to `mic.raw`, which the
/// stand-in reads when the stock firmware records (it starts from the newest audio each time a record
/// stream opens). Speaker: the stand-in appends what the firmware plays to `speaker.raw` as s16le 48 kHz
/// stereo, and marks where each played stream starts and ends in `speaker.events`. The emulator runs
/// at about 1/8 of real time, so a stream is produced 8x slower than it plays: this keeps every
/// utterance whole (it starts playing a stream once it has ended, or in 10 s pieces for long streams)
/// instead of stuttering. On the input side the stand-in drops silence from the backlog, so speech is
/// delivered whole and the delay does not keep growing.
final class AudioBridge {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let micURL: URL
    private let speakerURL: URL
    private let queue = DispatchQueue(label: "rayneo.audio")
    private var micHandle: FileHandle?
    private var speakerHandle: FileHandle?
    private var speakerOffset: UInt64 = 0
    private let eventsURL: URL
    private let playedURL: URL
    static let chunkBytes: UInt64 = 48_000 * 4 * 10
    private var poll: DispatchSourceTimer?
    private var micConverter: AVAudioConverter?
    let wake = WakeWordListener()
    private var micBytes: UInt64 = 0
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let speakerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    init(runDirectory: URL) {
        micURL = runDirectory.appendingPathComponent("mic.raw")
        speakerURL = runDirectory.appendingPathComponent("speaker.raw")
        eventsURL = runDirectory.appendingPathComponent("speaker.events")
        playedURL = runDirectory.appendingPathComponent("speaker.played")
        FileManager.default.createFile(atPath: playedURL.path, contents: nil)
        FileManager.default.createFile(atPath: micURL.path, contents: nil)
    }

    var micPath: String { micURL.path }

    func start(microphone: Bool) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)
        if microphone { startMicrophone() }
        do { try engine.start(); player.play() } catch { NSLog("AudioBridge: \(error)") }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.pumpSpeaker() }
        timer.resume()
        poll = timer
    }

    func stop() {
        poll?.cancel(); poll = nil
        wake.stop()
        engine.inputNode.removeTap(onBus: 0)
        player.stop(); engine.stop()
        try? micHandle?.close(); micHandle = nil
        try? speakerHandle?.close(); speakerHandle = nil
    }

    private func startMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: micFormat) else { return }
        micConverter = converter
        micHandle = try? FileHandle(forWritingTo: micURL)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.queue.async { self?.writeMicrophone(buffer) }
        }
        wake.start()
    }

    private func writeMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let converter = micConverter, let handle = micHandle else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * micFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        handle.seekToEndOfFile()
        handle.write(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
        micBytes += UInt64(out.frameLength) * 2
        wake.append(buffer, micBytes: micBytes)
    }

    /// Bytes of speaker.raw that may be played now: up to the end of a finished stream, or whole
    /// `chunk`-byte pieces of a stream that is still being produced. `events` is speaker.events
    /// ("<offset> start|end <stream>" per line); without it everything written so far is playable.
    static func playableLimit(events: String?, fileSize: UInt64, played: UInt64, chunk: UInt64 = chunkBytes) -> UInt64 {
        guard let events else { return fileSize }
        var openStart: UInt64? = nil
        var limit = played
        for line in events.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let offset = UInt64(parts[0]) else { continue }
            if parts[1] == "start" { if openStart == nil { openStart = offset } }
            else if parts[1] == "end" { limit = max(limit, min(offset, fileSize)); openStart = nil }
        }
        if let start = openStart, fileSize > max(start, played) {
            let from = max(start, played)
            limit = max(limit, from + (fileSize - from) / chunk * chunk)
        }
        return min(limit, fileSize)
    }

    private func pumpSpeaker() {
        if speakerHandle == nil {
            guard FileManager.default.fileExists(atPath: speakerURL.path) else { return }
            speakerHandle = try? FileHandle(forReadingFrom: speakerURL)
        }
        guard let handle = speakerHandle else { return }
        let size = handle.seekToEndOfFile()
        let limit = Self.playableLimit(events: try? String(contentsOf: eventsURL, encoding: .utf8), fileSize: size, played: speakerOffset)
        guard limit > speakerOffset else { return }
        handle.seek(toFileOffset: speakerOffset)
        let data = handle.readData(ofLength: Int(min(limit - speakerOffset, 48_000 * 4 * 2)))
        let frames = data.count / 4
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        speakerOffset += UInt64(frames * 4)
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
            for i in 0..<frames {
                left[i] = Float(Int16(littleEndian: s[2 * i])) / 32768
                right[i] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
            }
        }
        let end = speakerOffset
        player.scheduleBuffer(buffer) { [weak self] in
            // evidence for tests: what reached the Mac output, as speaker.raw offsets
            guard let self else { return }
            let line = "\(end) played \(String(format: "%.3f", Date().timeIntervalSince1970))\n"
            if let h = try? FileHandle(forWritingTo: self.playedURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        }
    }
}
