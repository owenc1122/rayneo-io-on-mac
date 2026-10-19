import AVFoundation
import Speech

/// Second-stage wake word for live use: macOS on-device speech recognition listens to the same Mac
/// microphone the emulator gets and reports 「小雷小雷」 (hifi event 4) or "OK/Hey RayNeo" (2/3) with the
/// mic.raw byte offset where it ended. The HiFi4 stand-in counts the hit when its (virtual-time)
/// microphone timeline reaches that audio, standing in for the DSP's own KWS library. The stock BTH
/// first stage still runs on the emulated BTH. Nothing leaves the Mac (on-device recognition only).
final class WakeWordListener {
    var onKeyword: ((_ micOffset: UInt64, _ event: Int) -> Void)?
    private var recognizers: [(SFSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?)] = []
    private var lastHit: [Int: Date] = [:]
    private let lock = NSLock()
    private var started = Date()

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { NSLog("WakeWordListener: speech recognition not authorised"); return }
            DispatchQueue.main.async { self?.begin() }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        for (_, request, task) in recognizers { request?.endAudio(); task?.cancel() }
        recognizers.removeAll()
    }

    /// Microphone audio (any format) and the mic.raw size in bytes after this buffer was written.
    func append(_ buffer: AVAudioPCMBuffer, micBytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        currentBytes = micBytes
        for (_, request, _) in recognizers { request?.append(buffer) }
        if Date().timeIntervalSince(started) > 50 { restartLocked() }   // recognition tasks are limited to ~1 min
    }

    private var currentBytes: UInt64 = 0

    private func begin() {
        lock.lock(); defer { lock.unlock() }
        recognizers = ["zh-CN", "en-US"].compactMap { id in
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition else { return nil }
            return (r, nil, nil)
        }
        restartLocked()
    }

    private func restartLocked() {
        started = Date()
        for i in recognizers.indices {
            recognizers[i].1?.endAudio(); recognizers[i].2?.cancel()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            let english = recognizers[i].0.locale.identifier.hasPrefix("en")
            request.contextualStrings = english ? ["OK RayNeo", "Hey RayNeo", "RayNeo"] : ["小雷小雷", "小雷"]
            let task = recognizers[i].0.recognitionTask(with: request) { [weak self] result, _ in
                guard let self, let text = result?.bestTranscription.formattedString else { return }
                self.check(text, english: english)
            }
            recognizers[i].1 = request; recognizers[i].2 = task
        }
    }

    private func check(_ text: String, english: Bool) {
        let event: Int?
        if english {
            let t = text.lowercased().replacingOccurrences(of: "[^a-z ]", with: " ", options: .regularExpression)
            let neo = t.range(of: "ray ?neo|rayneo|rain ?yo|ray ?new|rainy o", options: .regularExpression) != nil
            event = !neo ? nil : t.range(of: "(^| )(ok|okay|o k)( |$)", options: .regularExpression) != nil ? 2
                : t.range(of: "(^| )hey( |$)", options: .regularExpression) != nil ? 3 : nil
        } else {
            // Mandarin: compare by pinyin so 小雷 / 晓蕾 / 小蕾 ... all count as "xiao lei"
            let latin = (text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
                .applyingTransform(.stripDiacritics, reverse: false) ?? text
            let p = latin.lowercased().replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
            event = p.contains("xiaoleixiaolei") || p.hasSuffix("xiaolei") && p.count <= 16 ? 4 : nil
        }
        guard let event else { return }
        if let last = lastHit[event], Date().timeIntervalSince(last) < 3 { return }
        lastHit[event] = Date()
        // the keyword ended a moment before the recogniser reported it
        let offset = currentBytes > 9_600 ? currentBytes - 9_600 : 0
        onKeyword?(offset, event)
        lock.lock(); restartLocked(); lock.unlock()
    }
}
