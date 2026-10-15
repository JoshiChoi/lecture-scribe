// Apple's older speech recognition (SFSpeechRecognizer, the engine behind macOS's Dictation) for macOS 14.2–15, where
// SpeechAnalyzer doesn't exist. On the device only: a request never goes to Apple's servers, and a language whose model
// isn't on the Mac isn't offered (LectureLanguage.available). It was made for short dictation, not hour-long lectures,
// so the lecture goes to it in pieces — cut at a pause once a piece has 20 s, never longer than 55 s — and each piece's
// results are split into sentences by their punctuation and word times. The utterance in progress is the grey preview.
// Within a piece it works utterance by utterance: at each pause it sends the utterance once more, complete and timed
// (`speechRecognitionMetadata` set), then starts its text afresh — the piece's final result holds only the last one —
// so each utterance is written when it completes (measured on macOS 27).
// It runs one recognition task at a time — a new task ends the one before it with "no speech" (measured on macOS 27) —
// so the next piece's sound waits until the previous piece's final result is in, then goes to it all at once.

import AVFoundation
import Foundation
import Speech

@MainActor
final class ClassicRecognizer: SpeechRecognizer {
    var onLine: ((Line) -> Void)?
    var onError: ((Error) -> Void)?

    private let locale: Locale
    private let feed: Feed
    private var nextID = 1
    private var previews: [Int: (id: Int, start: Double, text: String)] = [:]    // piece → its preview line
    private var written: [Int: (start: Double, end: Double, text: String)] = [:] // piece → its last utterance written
    private var resume: [Int: Double] = [:]          // piece → where its next utterance starts (s into the piece)
    private var done: Set<Int> = []
    private var failures = 0                       // pieces in a row that ended in an error other than "no speech"
    private var told = false
    private var progress = Date()                  // when a piece last ended
    private var watchdog: Timer?

    /// `live`: a lecture playing now (sound is never held up); otherwise a file, whose reading waits while the
    /// recognizer is more than a minute behind.
    init(locale: Locale, live: Bool = true) {
        self.locale = locale
        feed = Feed(live: live)
    }

    /// Speech Recognition permission: asked once (the prompt shows the app's NSSpeechRecognitionUsageDescription).
    static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let now = SFSpeechRecognizer.authorizationStatus()
        guard now == .notDetermined else { return now }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
    }

    func start() async throws {
        guard await Self.authorization() == .authorized else {
            throw EngineError(message: L("음성 인식 권한이 꺼져 있어 받아 적을 수 없습니다. 시스템 설정 › 개인정보 보호 및 보안 › 음성 인식에서 Arc 강의 받아쓰기를 켜십시오.",
                                         "Speech Recognition is turned off for this app, so it can't transcribe. Turn on Arc Lecture Transcriber (Arc 강의 받아쓰기) in System Settings › Privacy & Security › Speech Recognition."),
                              code: "speech_denied")
        }
        guard let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition else {
            throw EngineError(message: Self.unavailable, code: "speech_unavailable")
        }
        r.queue = .main
        r.defaultTaskHint = .dictation
        feed.configure(r) { [weak self] piece, offset, result, error in      // on the main queue (r.queue)
            MainActor.assumeIsolated { self?.result(piece, offset, result, error) }
        }
        // a piece whose sound has ended but whose result doesn't come in 20 s is given up (what it heard so far stays):
        // the pieces after it would wait for ever
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stuck = self.feed.stalled(after: 20) else { return }
                log("recognizer: piece \(stuck.index) gave no result 20 s after its end — moving on")
                stuck.task?.cancel()
                self.done.insert(stuck.index)
                self.keepPreview(stuck.index)
                self.progress = Date()
                self.feed.ended(stuck.index)
            }
        }
        log("recognizer: \(locale.identifier(.bcp47)) — Apple's older speech recognition, on the device")
    }

    static var unavailable: String {
        L("이 Mac에는 이 강의 언어를 받아 적을 Apple 음성 인식이 없습니다. 시스템 설정 › 키보드에서 받아쓰기를 켜고 이 언어를 추가한 뒤 다시 시도하십시오 — 또는 최신 macOS로 업데이트하십시오.",
          "This Mac doesn't have Apple's speech recognition for this lecture language. Turn on Dictation in System Settings › Keyboard and add this language, then try again — or update to the latest macOS.")
    }

    /// Any thread.
    nonisolated func push(_ buffer: AVAudioPCMBuffer) { feed.push(buffer) }

    /// Ends the piece being fed and waits for every piece's final result, in turn — for as long as they keep coming (a
    /// file's last minute can still be queued), but never 20 s without one.
    func finish() async {
        feed.close()
        progress = Date()
        while feed.open > 0 && Date().timeIntervalSince(progress) < 20 { try? await Task.sleep(for: .milliseconds(100)) }
        if feed.open > 0 { log("recognizer: results did not end, giving up waiting"); feed.cancelAll() }
        watchdog?.invalidate()
        keepPreviews()
    }

    func cancel() async {
        watchdog?.invalidate()
        feed.cancelAll()
    }

    /// A piece's result. A partial one is the utterance so far (the preview); a complete one (an utterance's end, or the
    /// piece's final result) is written as sentences, the first taking the preview's id. Previews have no word times:
    /// they start where the piece's last written utterance ended.
    private func result(_ piece: Int, _ offset: Double, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if env["LECTURE_DEBUG"] == "1", let r = result {
            let segs = r.bestTranscription.segments
            log("classic raw piece \(piece) final=\(r.isFinal) meta=\(r.speechRecognitionMetadata != nil) words=\(segs.count) "
                + "t=\(String(format: "%.1f", segs.first?.timestamp ?? -1))–\(String(format: "%.1f", (segs.last.map { $0.timestamp + $0.duration }) ?? -1)) "
                + r.bestTranscription.formattedString)
        }
        guard !done.contains(piece) else { return }
        if let result {
            let t = result.bestTranscription
            if result.isFinal || result.speechRecognitionMetadata != nil {
                write(piece, offset, t)
            } else {
                let text = Self.clean(t.formattedString)
                if !text.isEmpty {
                    // started afresh without sending the last utterance complete (an older macOS): keep what it showed
                    if let old = previews[piece], Self.restarted(old.text, text) { keepPreview(piece) }
                    let id = previews[piece]?.id ?? { let i = nextID; nextID += 1; return i }()
                    let start = previews[piece]?.start ?? offset + (resume[piece] ?? 0)
                    previews[piece] = (id, start, text)
                    onLine?(Line(id: id, start: start, text: text, final: false))
                }
            }
            if result.isFinal {
                done.insert(piece)
                progress = Date()
                failures = 0
                feed.ended(piece)
            }
            return
        }
        done.insert(piece)
        progress = Date()
        feed.ended(piece)
        keepPreview(piece)                       // what it heard before the error stays
        let ns = error.map { $0 as NSError }
        if env["LECTURE_DEBUG"] == "1" || !(ns?.domain == "kAFAssistantErrorDomain" && ns?.code == 1110) {
            log("recognizer: piece \(piece) ended: \(ns.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "no result")")
        }
        guard let ns, !(ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110) else { return }   // 1110: no speech in it
        failures += 1
        if failures >= 3 && !told {             // not one hiccup: it keeps failing
            told = true
            onError?(EngineError(message: Self.unavailable, code: "speech_unavailable"))
        }
    }

    /// A complete utterance — unless it is the one just written again (the final result repeats the last utterance).
    private func write(_ piece: Int, _ offset: Double, _ t: SFTranscription) {
        let segs = t.segments
        let start = segs.first?.timestamp ?? 0, end = segs.last.map { $0.timestamp + $0.duration } ?? 0
        if let w = written[piece], w.text == t.formattedString, abs(w.start - start) < 0.05, abs(w.end - end) < 0.05 { return }
        written[piece] = (start, end, t.formattedString)
        if end > 0 { resume[piece] = end }
        finals(piece, offset, t)
    }

    /// A partial result that shares nothing with the one before and is far shorter: a new utterance began.
    private static func restarted(_ old: String, _ new: String) -> Bool {
        guard old.count >= 6, new.count * 2 < old.count else { return false }
        return !old.hasPrefix(String(new.prefix(2)))
    }

    private func finals(_ piece: Int, _ offset: Double, _ t: SFTranscription) {
        let full = t.formattedString as NSString
        let segs = t.segments
        var lines: [(start: Double, end: Double, text: String)] = []
        var start: Double?, end = 0.0, text = ""
        for (i, s) in segs.enumerated() {
            // the word and whatever follows it up to the next word (its punctuation, a space)
            let from = s.substringRange.location, to = i + 1 < segs.count ? segs[i + 1].substringRange.location : full.length
            guard from != NSNotFound, from <= to, to <= full.length else { continue }
            let chunk = full.substring(with: NSRange(location: from, length: to - from))
            if start == nil { start = s.timestamp }
            text += chunk
            end = max(end, s.timestamp + s.duration)
            let next = i + 1 < segs.count ? segs[i + 1].timestamp : .infinity
            let sentence = chunk.trimmingCharacters(in: .whitespaces).last.map { ".?!。？！".contains($0) } ?? false
            if sentence || next - end > 1.2 || end - (start ?? end) > 20 {
                lines.append((start ?? 0, end, text)); start = nil; text = ""
            }
        }
        if let s = start { lines.append((s, end, text)) }
        if segs.isEmpty && full.length > 0 { lines = [(0, 0, full as String)] }
        if env["LECTURE_DEBUG"] == "1" { log("classic piece \(piece) at \(String(format: "%.1f", offset)) s, \(segs.count) words: \(full)") }
        var id = previews.removeValue(forKey: piece)?.id
        var wrote = false
        for (s, e, raw) in lines {
            let line = Self.clean(raw)
            guard !line.isEmpty else { continue }
            let lineID = id ?? { let i = nextID; nextID += 1; return i }()
            id = nil
            onLine?(Line(id: lineID, start: offset + s, text: line, final: true, end: e > 0 ? offset + e : 0))
            wrote = true
        }
        if let id, !wrote { onLine?(Line(id: id, start: offset, text: "", final: true)) }    // nothing after all
    }

    /// A piece that ended without a final result keeps its last preview as written.
    private func keepPreview(_ piece: Int) {
        guard let p = previews.removeValue(forKey: piece) else { return }
        onLine?(Line(id: p.id, start: p.start, text: p.text, final: true))
    }

    private func keepPreviews() {
        for piece in previews.keys.sorted() { keepPreview(piece) }
    }

    /// A line doesn't start with punctuation (as the recognizer may write it after a pause).
    private static func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0.isWhitespace || ".,!?。、，！？".contains($0) })
    }

    /// The audio side (capture threads): the pieces, the one being fed, and where to cut it. One piece runs at a time
    /// (`queue[0]`); a later one keeps its sound until its turn. A task is made outside the lock — the main queue takes
    /// the lock too (`ended`), and the framework may need the main queue meanwhile.
    private final class Feed: @unchecked Sendable {
        private final class Piece {
            let index: Int, offset: Double
            let request = SFSpeechAudioBufferRecognitionRequest()
            var task: SFSpeechRecognitionTask?
            var held: [AVAudioPCMBuffer] = []     // its sound until its task runs
            var heldSeconds = 0.0
            var started = false, streaming = false, cut = false
            var ended: Date?                      // when its task was told the sound is over
            init(index: Int, offset: Double) {
                self.index = index
                self.offset = offset
                request.requiresOnDeviceRecognition = true      // never Apple's servers
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                request.taskHint = .dictation
            }
        }

        private let live: Bool
        private let lock = NSCondition()
        private var recognizer: SFSpeechRecognizer?
        private var onResult: ((Int, Double, SFSpeechRecognitionResult?, Error?) -> Void)?
        private var queue: [Piece] = []             // pieces whose final result hasn't come, in order
        private var current: Piece?                 // the piece being fed
        private var count = 0
        private var total = 0.0, length = 0.0       // seconds fed in all, and to the piece being fed
        private var quiet = 0.0, level = 0.0        // how long it has been quiet; the speech level (halving every 5 s)
        private var closed = false, cancelled = false

        init(live: Bool) { self.live = live }

        var open: Int { lock.lock(); defer { lock.unlock() }; return queue.count }

        func configure(_ r: SFSpeechRecognizer, onResult: @escaping (Int, Double, SFSpeechRecognitionResult?, Error?) -> Void) {
            lock.lock(); defer { lock.unlock() }
            self.onResult = onResult
            recognizer = r
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            guard buffer.format.sampleRate > 0, let float = Feed.float(buffer) else { return }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate, rms = Feed.rms(float)
            lock.lock()
            // a file is read far faster than this recognizer works: its reading waits while a minute of sound is held
            while !live && !closed && queue.reduce(0, { $0 + $1.heldSeconds }) > 60 { lock.wait(until: Date().addingTimeInterval(0.5)) }
            guard !closed, recognizer != nil else { lock.unlock(); return }
            if current == nil {
                count += 1
                let p = Piece(index: count, offset: total)
                queue.append(p)
                current = p
                length = 0
                quiet = 0
            }
            let p = current!
            if p.streaming { p.request.append(float) } else { p.held.append(float); p.heldSeconds += seconds }
            total += seconds
            length += seconds
            level = max(level * pow(0.5, seconds / 5), rms)
            quiet = rms < level * 0.15 ? quiet + seconds : 0
            if length >= 55 || (length >= 20 && quiet >= 0.35) || (length >= 40 && quiet >= 0.15) {
                if p.streaming { p.request.endAudio(); p.ended = Date() } else { p.cut = true }   // its final result follows
                current = nil                                                     // the next buffer starts a new piece
            }
            let next = startable()
            lock.unlock()
            if let next { launch(next) }
        }

        /// Under the lock: the first piece, if its task hasn't been made yet.
        private func startable() -> Piece? {
            guard let first = queue.first, !first.started else { return nil }
            first.started = true
            return first
        }

        /// Makes a piece's task, then hands it the sound it held (and its end, if it was cut meanwhile).
        private func launch(_ p: Piece) {
            lock.lock()
            let recognizer = self.recognizer, deliver = onResult
            lock.unlock()
            guard let recognizer, let deliver else { return }
            let task = recognizer.recognitionTask(with: p.request) { result, error in deliver(p.index, p.offset, result, error) }
            lock.lock()
            defer { lock.broadcast(); lock.unlock() }
            if cancelled { task.cancel(); return }
            p.task = task
            for b in p.held { p.request.append(b) }
            p.held = []
            p.heldSeconds = 0
            p.streaming = true
            if p.cut { p.request.endAudio(); p.ended = Date() }
        }

        /// The running piece, if its sound ended more than `seconds` ago and its result still hasn't come.
        func stalled(after seconds: Double) -> (index: Int, task: SFSpeechRecognitionTask?)? {
            lock.lock(); defer { lock.unlock() }
            guard let first = queue.first, let at = first.ended, Date().timeIntervalSince(at) > seconds else { return nil }
            return (first.index, first.task)
        }

        /// A piece's final result (or error) came: the next piece's turn. If the recognizer ended it by itself while it
        /// was still being fed (it heard the speech stop), the next buffer starts a new piece.
        func ended(_ index: Int) {
            lock.lock()
            if let i = queue.firstIndex(where: { $0.index == index }) {
                let p = queue.remove(at: i)
                if p === current { current = nil }
            }
            let next = startable()
            lock.broadcast()
            lock.unlock()
            if let next { launch(next) }
        }

        /// No more sound: the piece being fed ends; the pieces still open give their final results in turn.
        func close() {
            lock.lock()
            closed = true
            if let p = current { if p.streaming { p.request.endAudio(); p.ended = Date() } else { p.cut = true } }
            current = nil
            lock.broadcast()
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            closed = true
            cancelled = true
            let running = queue.compactMap(\.task)
            queue = []
            current = nil
            lock.broadcast()
            lock.unlock()
            running.forEach { $0.cancel() }
        }

        /// The capture's 16-bit samples as the 32-bit floats the recognizer takes.
        static func float(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if b.format.commonFormat == .pcmFormatFloat32 { return b }
            guard let src = b.int16ChannelData,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false),
                  let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(b.frameLength, 1)), let dst = out.floatChannelData
            else { return nil }
            out.frameLength = b.frameLength
            for i in 0..<Int(b.frameLength) { dst[0][i] = Float(src[0][i]) / 32768 }
            return out
        }

        static func rms(_ b: AVAudioPCMBuffer) -> Double {
            guard let d = b.floatChannelData, b.frameLength > 0 else { return 0 }
            var sum: Float = 0
            for i in 0..<Int(b.frameLength) { sum += d[0][i] * d[0][i] }
            return Double((sum / Float(b.frameLength)).squareRoot())
        }
    }
}
