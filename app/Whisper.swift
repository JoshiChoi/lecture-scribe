// The optional engines for 강의 받아쓰기 v2 on the Mac, run on this Mac's GPU: Whisper (whisper.cpp, large-v3-turbo),
// Qwen3-ASR (Korean and English, also mixed) and Parakeet (English lectures) — the last two through transcribe.cpp.
// Only the small runtimes are compiled into the app: each model and the voice detector they share are downloaded
// from 설정 › 음성 인식, checked against their published SHA-256, and can be removed there again.
//
// The pipeline is v1's: a voice detector cuts the audio at pauses, each piece is transcribed (long ones get live
// previews), and the engines' known failure modes are caught — phrases invented on silence, one phrase repeated over
// and over, and (Whisper) an English quote translated into Korean (or the reverse) instead of written down as spoken.

#if WHISPER
import Accelerate
import AVFoundation
import CryptoKit
import Foundation

// MARK: - Engines and their files

struct ModelFile: Sendable {
    let name: String, url: URL, bytes: Int64, sha256: String
}

/// An optional engine: what 설정 › 음성 인식 shows, the files it needs and the runtime that runs it.
struct EngineSpec: Sendable {
    enum Runtime: Sendable { case whisper, transcribe }
    let id: String, name: String, model: String, descKo: String, descEn: String
    let files: [ModelFile]                     // the voice detector first (one copy, shared), then the model
    let languages: [String]                    // the lecture languages (강의 언어) it writes
    let runtime: Runtime
    var desc: String { L(descKo, descEn) }         // in the app's language as it is now (it can change while running)
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var modelFile: ModelFile { files[files.count - 1] }
}

private func hf(_ path: String) -> URL { URL(string: "https://huggingface.co/" + path)! }

/// The voice detector every engine cuts the audio with.
let vadFile = ModelFile(name: "ggml-silero-v5.1.2.bin",
                        url: hf("ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"),
                        bytes: 885_098, sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf")

/// Pinned to a commit: a file can't change under its checksum.
let engineSpecs = [
    EngineSpec(id: "whisper", name: "Whisper", model: "large-v3 turbo",
               descKo: "OpenAI의 공개 모델을 이 Mac에서 실행합니다 · Apple보다 전력을 더 사용합니다", descEn: "Runs OpenAI's open model on this Mac · Uses more power than Apple's",
               files: [vadFile, ModelFile(name: "ggml-large-v3-turbo-q5_0.bin",
                                          url: hf("ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"),
                                          bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")],
               languages: ["ko", "en"], runtime: .whisper),
    EngineSpec(id: "qwen3", name: "Qwen3-ASR", model: "1.7B",
               descKo: "Alibaba의 공개 모델 · 한국어와 영어가 섞여도, 억양이 강한 영어도 정확합니다", descEn: "Alibaba's open model · Accurate even when Korean and English are mixed, and with strongly accented English",
               files: [vadFile, ModelFile(name: "Qwen3-ASR-1.7B-Q5_K_M.gguf",
                                          url: hf("handy-computer/Qwen3-ASR-1.7B-gguf/resolve/3555bd238a8572bbace3ebf60d23b036dc0a5dbe/Qwen3-ASR-1.7B-Q5_K_M.gguf"),
                                          bytes: 1_517_290_464, sha256: "034c557fe92ff8fcd9a9c041cbdaad347be0a86a58d3a348f63cf3f0180879d0")],
               languages: ["ko", "en"], runtime: .transcribe),
    EngineSpec(id: "parakeet", name: "Parakeet", model: "0.6B",
               descKo: "NVIDIA의 공개 모델 · 영어 강의 전용 — 한국어로 한 말은 빠지거나 엉뚱한 영어로 적힙니다 · 내려받는 엔진 중 가장 빠르고 가볍습니다", descEn: "NVIDIA's open model · For English lectures only — anything said in Korean is dropped or written as made-up English · The fastest and lightest of the downloadable engines",
               files: [vadFile, ModelFile(name: "parakeet-unified-en-0.6b-Q5_K_M.gguf",
                                          url: hf("handy-computer/parakeet-unified-en-0.6b-gguf/resolve/d5249700b2382bf5c5024c2421d101b8db54a629/parakeet-unified-en-0.6b-Q5_K_M.gguf"),
                                          bytes: 540_795_264, sha256: "f9def6f9b4e83ab7d006df3e1b676dfa1f973a3b6da232a9c99fcaa66bcd2836")],
               languages: ["en"], runtime: .transcribe),
]

private let appBuildVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")"

/// Application Support/LectureScribe/Models (inside the app's container). Tests: LECTURE_MODEL_DIR.
let modelDir: URL = env["LECTURE_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureScribe/Models")

func modelPath(_ f: ModelFile) -> String { modelDir.appendingPathComponent(f.name).path }

/// Downloads, checks and removes one engine's files (the Engine runs one download at a time); progress goes to the page.
@MainActor
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable { case absent, downloading(Double), verifying, ready, failed(String) }
    nonisolated let spec: EngineSpec
    private(set) var state: State = .absent { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// A download the user started has finished.
    var onReady: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?                   // a download cut off by the network continues where it stopped
    private var resumeIndex = -1
    private var index = 0
    private var needBytes: Int64 = 1                // what this download fetches (the shared voice detector may be here)
    private var doneBytes: Int64 = 0
    private var lastReport = Date.distantPast
    private static var tidied = false

    init(spec: EngineSpec) {
        self.spec = spec
        super.init()
        if !ModelStore.tidied, let left = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) {   // an interrupted download
            ModelStore.tidied = true
            for f in left where f.hasSuffix(".part") { try? FileManager.default.removeItem(at: modelDir.appendingPathComponent(f)) }
        }
        state = installed ? .ready : .absent
    }

    nonisolated static func complete(_ f: ModelFile) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: modelPath(f))[.size] as? NSNumber)?.int64Value == f.bytes
    }
    nonisolated var installed: Bool { spec.files.allSatisfy(ModelStore.complete) }

    var downloading: Bool { task != nil }

    /// Bytes still to download.
    nonisolated var missingBytes: Int64 { spec.files.filter { !ModelStore.complete($0) }.reduce(Int64(0)) { $0 + $1.bytes } }

    func download() {
        guard task == nil, state != .ready else { return }
        needBytes = max(1, missingBytes); doneBytes = 0
        let need = needBytes + 500_000_000
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? need
        guard free >= need else {
            let gb = ["ko", "en"].contains(appLanguage.value) ? String(format: "%.1f", Double(need) / 1e9)       // "2,5" where the
                : (Double(need) / 1e9).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: appLanguage.value)))   // language says so
            state = .failed(L("저장 공간이 부족합니다. \(gb)GB 이상 비운 뒤 다시 시도하십시오.", "Not enough free space. Free up at least \(gb) GB, then try again."))
            return
        }
        do { try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true) } catch {
            state = .failed(L("모델을 저장할 폴더를 만들지 못했습니다.", "Couldn't create a folder for the model.")); return
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        index = 0
        log("\(spec.id): model download started")
        next()
    }

    private func next() {
        while index < spec.files.count, ModelStore.complete(spec.files[index]) { index += 1 }   // the shared voice detector may be here already
        guard index < spec.files.count, let session else { return finished() }
        let f = spec.files[index]
        let url = env["LECTURE_MODEL_URL"].flatMap { URL(string: $0)?.appendingPathComponent(f.name) } ?? f.url   // tests: a local server
        let t: URLSessionDownloadTask
        if let data = resumeData, resumeIndex == index { t = session.downloadTask(withResumeData: data); log("\(spec.id): resuming the download") }
        else { t = session.downloadTask(with: url) }
        resumeData = nil
        task = t
        t.resume()
        report(0, force: true)
    }

    private func report(_ written: Int64, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReport) >= 0.25 else { return }
        lastReport = Date()
        state = .downloading(min(0.999, Double(doneBytes + written) / Double(needBytes)))
    }

    private func finished() {
        session?.finishTasksAndInvalidate()
        session = nil; task = nil
        guard installed else { state = .failed(L("모델을 내려받지 못했습니다. 다시 시도하십시오.", "Couldn't download the model. Try again.")); return }
        // The very first load compiles the model's GPU programs (up to a minute, once; macOS keeps them): do it now,
        // while the page still says "확인 중", so the first recording with this engine starts at once.
        state = .verifying
        let spec = self.spec
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            WhisperCore.warmUp(spec)
            log(String(format: "\(spec.id): warmed up in %.1f s", Date().timeIntervalSince(t0)))
            await MainActor.run {
                guard self.task == nil, self.session == nil, self.installed else { return }
                self.state = .ready
                log("\(spec.id): model ready")
                self.onReady?()
            }
        }
    }

    private func fail(_ message: String) {
        task = nil
        session?.invalidateAndCancel(); session = nil
        state = .failed(message)
    }

    func cancel() {
        resumeData = nil
        guard task != nil else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil; session = nil
        state = installed ? .ready : .absent
        log("\(spec.id): download cancelled")
    }

    /// `shared`: files another engine still uses (the voice detector) stay.
    func remove(keeping shared: Set<String> = []) {
        cancel()
        for f in spec.files where !shared.contains(f.name) { try? FileManager.default.removeItem(atPath: modelPath(f)) }
        state = .absent
        log("\(spec.id): model removed")
    }

    /// A shared file went (another engine's check removed it): this engine has to be downloaded again too.
    func refresh() {
        if state == .ready, !installed { state = .absent }
    }

    /// The model didn't load: check the files against their checksums (in the background). Damaged or missing files are
    /// removed, so 설정 › 음성 인식 offers the download again instead of failing at every recording.
    func recheck() {
        guard state == .ready, task == nil else { return }
        let spec = self.spec
        Task.detached(priority: .utility) {
            let bad = spec.files.filter { !ModelStore.verify(URL(fileURLWithPath: modelPath($0)), $0) }
            let missing = bad.contains { !FileManager.default.fileExists(atPath: modelPath($0)) }
            await MainActor.run {
                guard !bad.isEmpty else { log("\(spec.id): the model files are intact"); return }
                guard self.state == .ready, self.task == nil else { return }
                for f in bad { try? FileManager.default.removeItem(atPath: modelPath(f)) }
                log("\(spec.id): removed damaged or missing files: \(bad.map(\.name).joined(separator: ", "))")
                self.state = .failed(missing ? L("모델 파일이 없어졌습니다. 다시 내려받으십시오.", "The model file is missing. Download it again.") : L("모델 파일이 손상되어 삭제했습니다. 다시 내려받으십시오.", "The model file was damaged and has been deleted. Download it again."))
            }
        }
    }

    /// After an app update the GPU programs are compiled again on the first load (20–40 s): for the chosen engine, do
    /// that quietly in the background once per build, so the next recording starts at once.
    func warmUpIfUpdated(selected: Bool) {
        guard selected, state == .ready, env["LECTURE_TEST_NO_WARMUP"] == nil else { return }
        let exe = Bundle.main.executableURL.map { $0.path } ?? CommandLine.arguments[0]
        let built = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(spec.id)Warm", stamp = "\(appBuildVersion)-\(Int(built))", spec = self.spec
        guard UserDefaults.standard.string(forKey: key) != stamp else { return }
        Task.detached(priority: .background) {
            let t0 = Date()
            WhisperCore.warmUp(spec)
            log(String(format: "\(spec.id): warmed up for this build in %.1f s", Date().timeIntervalSince(t0)))
            UserDefaults.standard.set(stamp, forKey: key)
        }
    }

    /// For the page (설정 › 음성 인식).
    var info: [String: Any] {
        var d: [String: Any] = ["id": spec.id, "name": spec.name, "model": spec.model, "desc": spec.desc,
                                "bytes": spec.bytes, "removable": true, "languages": spec.languages]
        switch state {                                   // bytes: what a download fetches; once ready, what 삭제 frees
        case .absent: d["state"] = "absent"; d["bytes"] = missingBytes > 0 ? missingBytes : spec.bytes
        case .downloading(let p): d["state"] = "downloading"; d["progress"] = (p * 1000).rounded() / 1000; d["bytes"] = needBytes
        case .verifying: d["state"] = "downloading"; d["progress"] = 1; d["verifying"] = true; d["bytes"] = needBytes
        case .ready: d["state"] = "ready"
        case .failed(let m): d["state"] = "failed"; d["error"] = m; d["bytes"] = missingBytes > 0 ? missingBytes : spec.bytes
        }
        return d
    }

    // MARK: URLSession (delegate queue: main)

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        MainActor.assumeIsolated { if downloadTask === self.task { self.report(totalBytesWritten) } }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let part = modelDir.appendingPathComponent(UUID().uuidString + ".part")      // the temporary file is gone after this returns
        let moved = (try? FileManager.default.moveItem(at: location, to: part)) != nil
        MainActor.assumeIsolated { self.received(downloadTask, part: moved ? part : nil, status: status) }
    }

    nonisolated func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard t === self.task, (error as NSError).code != NSURLErrorCancelled else { return }
            log("\(self.spec.id): download failed: \(error)")
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {   // 다시 시도 continues from here
                self.resumeData = data; self.resumeIndex = self.index
            }
            self.fail((error as NSError).code == NSURLErrorNotConnectedToInternet
                      ? L("인터넷에 연결되어 있지 않습니다. 연결한 뒤 다시 시도하십시오.", "You're not connected to the internet. Connect, then try again.") : L("모델을 내려받지 못했습니다. 잠시 후 다시 시도하십시오.", "Couldn't download the model. Try again in a moment."))
        }
    }

    private func received(_ t: URLSessionDownloadTask, part: URL?, status: Int) {
        guard t === task, let part, status == 200 else {
            if let part { try? FileManager.default.removeItem(at: part) }
            if t === task { log("\(spec.id): download HTTP \(status)"); fail(L("모델을 내려받지 못했습니다. 잠시 후 다시 시도하십시오.", "Couldn't download the model. Try again in a moment.")) }
            return
        }
        let f = spec.files[index]
        if index == spec.files.count - 1 { state = .verifying }          // the voice detector checks in a blink
        Task.detached(priority: .userInitiated) {
            let ok = ModelStore.verify(part, f)
            await MainActor.run {
                guard t === self.task else { try? FileManager.default.removeItem(at: part); return }     // cancelled meanwhile
                guard ok else {
                    try? FileManager.default.removeItem(at: part)
                    log("\(self.spec.id): \(f.name) failed its checksum")
                    self.fail(L("내려받은 파일이 올바르지 않습니다. 다시 시도하십시오.", "The downloaded file isn't valid. Try again.")); return
                }
                try? FileManager.default.removeItem(atPath: modelPath(f))
                do { try FileManager.default.moveItem(atPath: part.path, toPath: modelPath(f)) } catch {
                    self.fail(L("모델을 저장하지 못했습니다.", "Couldn't save the model.")); return
                }
                self.index += 1
                self.doneBytes += f.bytes
                self.next()
            }
        }
    }

    nonisolated static func verify(_ url: URL, _ f: ModelFile) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var sha = SHA256(), n: Int64 = 0
        // each chunk freed before the next: without the pool a 1.5 GB model stayed in memory until the end
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
            sha.update(data: chunk); n += Int64(chunk.count)
            return true
        }) {}
        return n == f.bytes && sha.finalize().map { String(format: "%02x", $0) }.joined() == f.sha256
    }
}

// MARK: - Recognizer

/// One downloaded engine's speech recognition for one session (Whisper, Qwen3-ASR or Parakeet). The model loads while
/// the first audio is already buffered, so 시작 responds at once. If it can't be loaded at all (a damaged file, the GPU
/// refusing it), Apple's recognizer takes over the session with everything heard so far — the transcript never just stops.
@MainActor
final class WhisperRecognizer: SpeechRecognizer {
    var onLine: ((Line) -> Void)?
    var onError: ((Error) -> Void)?
    /// The model didn't load and Apple's recognizer took over (the engine then checks the model files).
    var onFallback: (() -> Void)?
    private let core: WhisperCore
    private var apple: SpeechRecognizer?
    /// Apple's recognizer for the lecture language (Engine.appleRecognizer) — what takes over when the model doesn't load.
    var makeApple: (() -> SpeechRecognizer)?
    private var takeover: Task<Void, Never>?

    /// `major`: the lecture's language (강의 언어), "ko" or "en"; the other one is written where it is spoken.
    init(live: Bool, major: String = "ko", spec: EngineSpec) { core = WhisperCore(live: live, major: major, spec: spec) }

    func start() async throws {
        core.deliver = { [weak self] line in DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLine?(line) } } }
        core.failed = { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.onError?(e) } } }
        core.loadFailed = { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.fallBack(e) } } }
        core.run()
    }

    nonisolated func push(_ buffer: AVAudioPCMBuffer) { core.push(buffer) }

    func finish() async {
        await offMain { $0.finish() }
        if let e = core.failure { fallBack(e) }              // failed while 정지 was pressed: the audio still gets transcribed
        await takeover?.value
        await apple?.finish()
    }

    func cancel() async {
        await offMain { $0.cancel() }
        await takeover?.value
        await apple?.cancel()
    }

    private func fallBack(_ error: Error) {
        guard takeover == nil else { return }
        let core = self.core, apple: SpeechRecognizer
        if let make = makeApple { apple = make() }
        else if #available(macOS 26, iOS 26, *), LectureLanguage.modern { apple = Recognizer(main: core.major) }
        else { apple = ClassicRecognizer(locale: Locale(identifier: core.major == "en" ? "en-US" : "ko-KR")) }
        apple.onLine = { [weak self] in self?.onLine?($0) }
        apple.onError = { [weak self] in self?.onError?($0) }
        self.apple = apple
        onFallback?()
        takeover = Task { [weak self] in
            do {
                try await apple.start()
                core.handOver { apple.push($0) }
                if (apple as? ClassicRecognizer)?.transcribing == false {       // macOS 14/15: its own notice says why
                    log("\(core.spec.id): Apple's older recognizer couldn't take over either")
                    return
                }
                log("\(core.spec.id): Apple's recognizer took over")
                self?.onError?(EngineError(message: L("\(core.spec.name) 모델을 열지 못해서 이번 녹음은 Apple 음성 인식으로 받아 적습니다. 지금까지 들린 내용도 빠짐없이 받아 적습니다.", "Couldn't open the \(core.spec.name) model, so Apple Speech Recognition will transcribe this recording. Everything heard so far will be transcribed too, with nothing left out.")))
            } catch {
                core.abandon()
                self?.apple = nil
                log("\(core.spec.id): Apple's recognizer couldn't take over: \(error)")
                self?.onError?(EngineError(message: L("음성 인식을 시작하지 못했습니다. 녹음은 계속됩니다.", "Couldn't start speech recognition. Recording continues.")))
            }
        }
    }

    private func offMain(_ f: @escaping @Sendable (WhisperCore) -> Void) async {
        let core = self.core
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { f(core); c.resume() }
        }
    }
}

/// How sure Whisper was of the language it detected in the last "auto" decode. Its API keeps the probability to
/// itself, so it is read from its log line ("auto-detected language: en (p = 0.504676)"); one worker thread decodes.
private let detectedP = AtomicValue()

final class AtomicValue: @unchecked Sendable {
    private let lock = NSLock(); private var v: Float = 0
    var value: Float {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// A model failed to load in this run: its half-made GPU state makes ggml's teardown abort at exit ("quit
/// unexpectedly"), so the app then leaves with `_exit` once everything is saved (main.swift `quit`).
let whisperLoadFailed = AbortFlag()

/// transcribe.cpp's messages go to the app log (warnings and errors; everything with LECTURE_DEBUG). Set once.
private let transcribeLogging: Void = transcribe_log_set({ level, msg, _ in
    guard let msg, level == TRANSCRIBE_LOG_LEVEL_WARN || level == TRANSCRIBE_LOG_LEVEL_ERROR || env["LECTURE_DEBUG"] == "1" else { return }
    let line = String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines)
    if !line.isEmpty { log("transcribe: " + line) }
}, nil)

final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Phrases Whisper is known to invent on silence or noise (video outro boilerplate) — dropped only when they are
/// the whole piece. Same list as v1.
private let hallucinations = ["시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요 부탁드립니다",
                              "구독 좋아요 알림설정", "구독과 좋아요", "MBC 뉴스", "KBS 뉴스", "SBS 뉴스", "YTN 뉴스",
                              "자막 제공", "한글자막", "자막 by", "Thank you for watching", "다음 영상에서 만나요"]
    .map { $0.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }

/// Whisper's failure mode: the same phrase over and over. (start word, phrase length, repeats) or nil.
func whisperLoop(_ text: String) -> (Int, Int, Int)? {
    let w = text.split(separator: " ").map(String.init)
    for n in 1...6 {
        let need = n == 1 ? 6 : 4
        guard w.count >= n * need else { continue }
        for i in 0...(w.count - n * need) {
            var k = 1
            while i + (k + 1) * n <= w.count, Array(w[(i + k * n)..<(i + (k + 1) * n)]) == Array(w[i..<(i + n)]) { k += 1 }
            if k >= need { return (i, n, k) }
        }
    }
    return nil
}

/// Keeps two of the repeats and marks the rest with "…".
func whisperCollapse(_ text: String) -> String {
    var w = text.split(separator: " ").map(String.init)
    for _ in 0..<20 {
        guard let (i, n, k) = whisperLoop(w.joined(separator: " ")) else { break }
        w = Array(w[..<(i + 2 * n)]) + ["…"] + Array(w[(i + k * n)...])
    }
    return w.joined(separator: " ")
}

/// Everything the worker thread touches. Audio arrives on capture threads; the model runs on one worker thread.
private final class WhisperCore: @unchecked Sendable {
    let live: Bool
    let major: String                          // the lecture's language: "ko" or "en"
    let spec: EngineSpec
    private var minor: String { major == "en" ? "ko" : "en" }
    var deliver: (Line) -> Void = { _ in }
    var failed: (Error) -> Void = { _ in }
    /// The model couldn't be loaded. The audio keeps being collected until `handOver` passes it on.
    var loadFailed: (Error) -> Void = { _ in }

    private var ctx: OpaquePointer?                // Whisper
    private var session: OpaquePointer?            // Qwen3-ASR, Parakeet (transcribe.cpp)
    private var vad: OpaquePointer?
    private let cond = NSCondition()
    private var input: [Float] = []
    private var head = 0                       // samples of `input` already handed to the worker
    private var closing = false
    private var running = false
    private var loadError: Error?
    private var forward: ((AVAudioPCMBuffer) -> Void)?     // after a failed load: where the audio goes instead
    private let abort = AbortFlag()

    init(live: Bool, major: String = "ko", spec: EngineSpec) {
        self.live = live; self.major = major == "en" ? "en" : "ko"; self.spec = spec
    }

    /// Loads the model once and frees it (after a download): macOS keeps the compiled GPU programs.
    static func warmUp(_ spec: EngineSpec) {
        let core = WhisperCore(live: false, spec: spec)
        try? core.load()
        core.release()
    }

    func run() {
        cond.lock(); running = true; cond.unlock()
        let t = Thread { [self] in work() }
        t.stackSize = 8 << 20
        t.qualityOfService = .userInitiated
        t.name = "lecture.\(spec.id)"
        t.start()
    }

    func push(_ buf: AVAudioPCMBuffer) {
        guard let p = buf.int16ChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var f = [Float](repeating: 0, count: n)
        f.withUnsafeMutableBufferPointer { b in
            vDSP_vflt16(p, 1, b.baseAddress!, 1, vDSP_Length(n))
            var s = Float(1.0 / 32768.0)
            vDSP_vsmul(b.baseAddress!, 1, &s, b.baseAddress!, 1, vDSP_Length(n))
        }
        cond.lock()
        // A file is read far faster than Whisper listens: stay at most ~30 s ahead (memory). Live audio never waits.
        while !live, forward == nil, input.count - head > 30 * 16000, !closing, !abort.value { _ = cond.wait(until: Date() + 0.5) }
        if let sink = forward { cond.unlock(); sink(buf); return }
        defer { cond.unlock() }
        guard !closing, !abort.value else { return }
        input.append(contentsOf: f)
        cond.broadcast()
    }

    private var isClosing: Bool { cond.lock(); defer { cond.unlock() }; return closing }

    /// Why the model didn't load, if it didn't.
    var failure: Error? { cond.lock(); defer { cond.unlock() }; return loadError }

    /// After a failed load: everything heard so far, then everything that follows, goes to `sink` — in order.
    func handOver(to sink: @escaping (AVAudioPCMBuffer) -> Void) {
        cond.lock(); defer { cond.unlock() }
        var i = head
        while i < input.count {
            let n = min(16000, input.count - i)
            guard let b = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
                  let p = b.int16ChannelData?[0] else { break }
            for k in 0..<n { p[k] = Int16(max(-32768, min(32767, (input[i + k] * 32768).rounded()))) }
            b.frameLength = AVAudioFrameCount(n)
            sink(b)
            i += n
        }
        input.removeAll(); head = 0
        forward = sink
        cond.broadcast()                                      // a file reader may be waiting for room
    }

    /// Nothing will take the audio after all: stop collecting it.
    func abandon() {
        abort.value = true
        cond.lock(); input.removeAll(); head = 0; cond.broadcast(); cond.unlock()
    }

    /// Transcribe what's left, then free the model (≤ 3 minutes, even if Whisper gets stuck).
    func finish() {
        cond.lock()
        closing = true
        cond.broadcast()
        let deadline = Date() + 180
        while running, Date() < deadline { _ = cond.wait(until: min(deadline, Date() + 1)) }
        let stuck = running
        cond.unlock()
        if stuck { log("\(spec.id): still busy after 3 minutes; stopping"); stop() } else { release() }
    }

    func cancel() { stop() }

    private func stop() {
        abort.value = true
        cond.lock()
        closing = true
        cond.broadcast()
        let deadline = Date() + 15
        while running, Date() < deadline { _ = cond.wait(until: min(deadline, Date() + 1)) }
        cond.unlock()
        release()
    }

    private func release() {
        cond.lock(); defer { cond.unlock() }
        guard !running else { return }                        // never free under a running decode
        if let v = vad { whisper_vad_free(v); vad = nil }
        if let c = ctx { whisper_free(c); ctx = nil }
        if let s = session { transcribe_session_free(s); session = nil }
    }

    // MARK: worker

    private func load() throws {
        whisper_log_set({ level, text, _ in                    // whisper.cpp is chatty: warnings and errors only
            guard let text else { return }
            if strstr(text, "auto-detected language:") != nil, let at = strstr(text, "(p = ") {
                detectedP.value = Float(String(cString: at + 5).prefix { "0123456789.".contains($0) }) ?? 0
            }
            guard level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR || env["LECTURE_DEBUG"] == "1" else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { log("whisper: " + line) }
        }, nil)
        let t0 = Date()
        var vp = whisper_vad_default_context_params()          // whisper.cpp's voice detector cuts the audio for every engine
        vp.n_threads = 1
        vp.use_gpu = false
        guard let v = whisper_vad_init_from_file_with_params(modelPath(vadFile), vp) else {
            throw EngineError(message: "the voice detector didn't load")
        }
        if spec.runtime == .transcribe {
            _ = transcribeLogging
            var sp = transcribe_session_params()
            transcribe_session_params_init(&sp)
            sp.n_threads = 4
            var s: OpaquePointer?
            let rc = transcribe_open(modelPath(spec.modelFile), nil, &sp, &s)
            guard rc == TRANSCRIBE_OK, let s else {
                whisper_vad_free(v)
                throw EngineError(message: "the model didn't load (\(String(cString: transcribe_status_string(Int32(rc.rawValue)))))")
            }
            transcribe_set_abort_callback(s, { $0.map { Unmanaged<AbortFlag>.fromOpaque($0).takeUnretainedValue().value } ?? false },
                                          Unmanaged.passUnretained(abort).toOpaque())
            session = s; vad = v
            log(String(format: "\(spec.id): model loaded in %.1f s on ", Date().timeIntervalSince(t0)) + String(cString: transcribe_model_backend(transcribe_get_model(s))))
            return
        }
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true                                   // measured: ~20% faster on an M2
        guard let c = whisper_init_from_file_with_params(modelPath(spec.modelFile), cp) else {
            whisper_vad_free(v)
            throw EngineError(message: "the model didn't load")
        }
        ctx = c; vad = v
        log(String(format: "whisper: model loaded in %.1f s · ", Date().timeIntervalSince(t0)) + String(cString: whisper_print_system_info()))
    }

    private func work() {
        let slow = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosing else { return }
            self.failed(EngineError(message: L("\(self.spec.name) 모델을 준비하는 중입니다. 처음 한 번은 1분쯤 걸립니다 — 그동안에도 녹음은 계속되고, 준비되면 이어서 받아 적습니다.", "Getting the \(self.spec.name) model ready. The first time takes about a minute — recording continues meanwhile, and transcription picks up once it's ready.")))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: slow)
        defer { slow.cancel() }
        do { try load(); slow.cancel() } catch {
            slow.cancel()
            whisperLoadFailed.value = true
            log("\(spec.id): \(error)")
            cond.lock(); loadError = error; running = false; cond.broadcast(); cond.unlock()
            loadFailed(error)                                 // the audio waits for Apple's recognizer
            return
        }
        let window = 512
        var ending = false
        while !ending, !abort.value {
            cond.lock()
            while input.count - head < window, !closing, !abort.value { cond.wait() }
            if abort.value { cond.unlock(); break }
            let available = input.count - head
            let take = closing ? available : min(available / window * window, 2 * 16000)    // ≤ 2 s at a time
            let chunk = Array(input[head..<(head + take)])
            head += take
            if head > 60 * 16000 { input.removeFirst(head); head = 0 }
            ending = closing && head == input.count
            cond.broadcast()                                  // a file reader may be waiting for room
            cond.unlock()
            listen(chunk)
        }
        if ending, !abort.value { flush() }
        cond.lock(); running = false; cond.broadcast(); cond.unlock()
    }

    /// Seconds of audio waiting for the worker. Live, Whisper may fall behind on a busy or slow Mac; then it skips
    /// previews and the extra language check until it has caught up (v1: previews only when the GPU is idle).
    private var backlog: Double {
        cond.lock(); defer { cond.unlock() }
        return Double(input.count - head) / 16000
    }

    private func listen(_ samples: [Float]) {
        guard !samples.isEmpty, let vad else { return }
        var s = samples
        if s.count % 512 != 0 { s += [Float](repeating: 0, count: 512 - s.count % 512) }
        let ok = s.withUnsafeBufferPointer { whisper_vad_detect_speech_no_reset(vad, $0.baseAddress, Int32($0.count)) }
        let n = Int(whisper_vad_n_probs(vad))
        guard ok, n == s.count / 512, let probs = whisper_vad_probs(vad) else { log("\(spec.id): voice detector failed"); return }
        for i in 0..<n { feed(s[(i * 512)..<((i + 1) * 512)], probs[i]) }
    }

    // v1's segmenter: groups 32 ms voice-detector frames into utterances, cut at pauses. Short phrases wait for a
    // longer pause (more context = better accuracy), long ones cut at shorter pauses; anything reaching 22 s is cut
    // at the quietest moment of its last 5 seconds.
    private let frameSec = 0.032
    private let startP: Float = 0.5, endP: Float = 0.35
    private let preFrames = 15, tailFrames = 9, maxSec = 22.0, minSpeechSec = 0.25
    private var pre: [Float] = []
    private var pos = 0
    private var active = false
    private var seg: [Float] = []
    private var probs: [Float] = []
    private var segStart = 0
    private var silence = 0
    private var lastPreview = 0.0
    private var nextID = 1, curID = 0, previewed = 0

    private func feed(_ frame: ArraySlice<Float>, _ p: Float) {
        defer { pos += 1 }
        if !active {
            pre.append(contentsOf: frame)
            if pre.count > preFrames * 512 { pre.removeFirst(pre.count - preFrames * 512) }
            guard p >= startP else { return }
            active = true
            seg = pre
            probs = [Float](repeating: 0, count: pre.count / 512 - 1) + [p]
            segStart = pos - pre.count / 512 + 1
            silence = 0; lastPreview = 0
            curID = nextID; nextID += 1
            pre.removeAll(keepingCapacity: true)
            return
        }
        seg.append(contentsOf: frame)
        probs.append(p)
        silence = p < endP ? silence + 1 : 0
        let length = Double(probs.count) * frameSec
        let need = length < 4 ? 1.2 : (length < 12 ? 0.6 : 0.3)
        if Double(silence) * frameSec >= need {
            let cut = probs.count - silence + min(silence, tailFrames)
            let after = Array(seg[(cut * 512)...])
            close(cut)
            active = false
            seg.removeAll(); probs.removeAll()
            pre = Array(after.suffix(preFrames * 512))        // pure silence: a safe pre-roll for the next utterance
        } else if length >= maxSec {
            let look = Int(5.0 / frameSec)
            var k = probs.count - look, best = Float.infinity
            for i in (probs.count - look)..<probs.count where probs[i] < best { best = probs[i]; k = i }
            k = max(k, 1)
            let restAudio = Array(seg[(k * 512)...]), restProbs = Array(probs[k...])
            close(k)
            seg = restAudio; probs = restProbs
            segStart += k
            silence = 0; lastPreview = 0
            curID = nextID; nextID += 1
        } else if live, length >= 3, length - lastPreview >= 4, backlog < 1 {
            let text = transcribe(seg, final: false)
            if !text.isEmpty { previewed = curID; deliver(Line(id: curID, start: Double(segStart) * frameSec, text: text, final: false)) }
            lastPreview = length
        }
    }

    private func close(_ cut: Int) {
        let start = Double(segStart) * frameSec
        let spoken = Double(probs.prefix(cut).filter { $0 >= startP }.count) * frameSec
        let text = spoken >= minSpeechSec ? transcribe(Array(seg.prefix(cut * 512)), final: true, voice: Array(probs.prefix(cut))) : ""
        if !text.isEmpty || previewed == curID {               // empty: withdraw the preview, if one was shown
            deliver(Line(id: curID, start: start, text: text, final: true, end: start + Double(cut) * frameSec))
        }
    }

    private func flush() {
        if active, !probs.isEmpty { close(probs.count) }
        active = false
        seg.removeAll(); probs.removeAll()
    }

    // MARK: decoding

    private struct Result {
        var text: String; var conf: Double; var lang: String; var parts: [(t0: Double, t1: Double, text: String)] = []
        var sure: Float = 1                                     // "auto": how sure Whisper was of `lang`
    }

    /// Korean or English, written down as spoken (never translated on purpose) — v1's rule: long finals detect their
    /// language; if that differs from the lecture's (강의 언어: Korean by default, or English), the piece is decoded both
    /// ways and the more confident reading wins, so a quote in the other language stays as spoken and a misheard
    /// sentence can't turn into a translation.
    private func transcribe(_ pcm: [Float], final: Bool, voice: [Float] = []) -> String {
        if spec.runtime == .transcribe {
            var text = transcribeOther(pcm, voice: final && (!live || backlog < 3) ? voice : [])
            // "commons.는": a full stop right before a Korean particle (Qwen3 ends an English phrase with one)
            text = text.replacingOccurrences(of: "\\.(?=[가-힣])", with: "", options: .regularExpression)
            if whisperLoop(text) != nil { log("\(spec.id): collapsing a repeated phrase"); text = whisperCollapse(text) }
            return clean(text)
        }
        let major = self.major, minor = self.minor
        let behind = live ? backlog : 0
        var r: Result
        if final, Double(pcm.count) / 16000 >= 2.5, behind < 3 {
            r = decode(pcm, language: "auto", beam: 5)
            if r.lang != "ko", r.lang != "en" {
                r = decode(pcm, language: major, beam: 5); r.lang = major
            } else if r.lang != major {
                let m = decode(pcm, language: major, beam: 5)
                if m.conf >= r.conf { r = m; r.lang = major }
            }
        } else {
            r = decode(pcm, language: major, beam: final && behind < 8 ? 5 : 1); r.lang = major
            // A short piece may be a quote in the other language ("Less is more." in a Korean lecture). If the lecture's
            // language pass wrote it in the other script anyway, read it again in that language (the Korean pass drops or
            // capitalises English words: "STAY HUNGRY"). If the pass can't make sense of it, it switches only when
            // Whisper itself identifies the other language: forced into a language, unclear speech comes out invented
            // ("잠깐만요" → "I'm done with you").
            if final, behind < 8, Double(pcm.count) / 16000 >= 0.6 {
                if written(r.text, in: minor) {
                    let e = decode(pcm, language: minor, beam: 5)
                    if written(e.text, in: minor), e.conf > -0.9 { r = e; r.lang = minor }
                } else if r.text.isEmpty || r.conf < -0.8 {
                    let a = decode(pcm, language: "auto", beam: 5)
                    if a.lang == minor, a.sure >= 0.9, written(a.text, in: minor), a.conf > -0.9 { r = a }
                }
            }
        }
        if final, !r.text.isEmpty, whisperLoop(r.text) != nil {      // the repetition failure: one more try, other language
            let other = r.lang == "ko" ? "en" : "ko"
            let r2 = decode(pcm, language: other, beam: 5)
            if !r2.text.isEmpty, whisperLoop(r2.text) == nil, r2.conf > r.conf { r = r2; r.lang = other }
        }
        if final, behind < 3, !voice.isEmpty { r = rescue(pcm, voice, r) }
        if whisperLoop(r.text) != nil { log("whisper: collapsing a repeated phrase"); r.text = whisperCollapse(r.text) }
        return r.text
    }

    /// Mostly Latin letters (English), not Hangul.
    private func latin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && Double(letters.filter { $0.isASCII }.count) >= 0.8 * Double(letters.count)
    }

    /// Mostly Hangul.
    private func hangul(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && Double(letters.filter { (0xAC00...0xD7A3).contains($0.value) }.count) >= 0.8 * Double(letters.count)
    }

    /// Written in the script of `lang` ("en": Latin, "ko": Hangul).
    private func written(_ text: String, in lang: String) -> Bool { lang == "en" ? latin(text) : hangul(text) }

    /// Speech the voice detector heard but no part of the transcript covers — typically a short English quote inside a
    /// mostly Korean piece, which Whisper leaves out. Each such utterance is decoded again with Whisper's own language
    /// identification and put in, in time order: English when Whisper identifies it as English (a reading forced into
    /// another language would be a translation), Korean only where Whisper's own timing shows a gap. Nothing the
    /// transcript already has is put in twice.
    private func rescue(_ pcm: [Float], _ voice: [Float], _ r: Result) -> Result {
        guard !r.parts.isEmpty else { return r }
        let frame = 0.032, dur = Double(pcm.count) / 16000
        // Whisper's segment times stretch over speech it left out (a segment "starts" where the previous one ended, the
        // first at 0:00): estimate where each segment's speech really began from its length (a wrong guess only costs a
        // check).
        let raw = r.parts
        var parts = r.parts
        for k in parts.indices { parts[k].t0 = max(parts[k].t0, parts[k].t1 - spokenLength(parts[k].text, rate: k == 0 ? 6 : 5)) }
        func covered(_ t: Double) -> Bool { parts.contains { t >= $0.t0 - 0.2 && t <= $0.t1 + 0.25 } }
        var runs: [(Int, Int)] = [], start: Int?, quiet = 0
        for (i, p) in voice.enumerated() {
            if p >= 0.5 && !covered(Double(i) * frame) { if start == nil { start = i }; quiet = 0 }
            else if let s0 = start { quiet += 1; if quiet > 4 { runs.append((s0, i - quiet)); start = nil; quiet = 0 } }
        }
        if let s0 = start { runs.append((s0, voice.count - 1)) }
        // the whole utterance around each uncovered stretch (to the pauses on either side), so no word is cut in half
        func edge(_ i: Int, _ step: Int) -> Int {
            var k = i, q = 0
            while k + step >= 0, k + step < voice.count, q <= 4 { k += step; q = voice[k] >= 0.5 ? 0 : q + 1 }
            return k - step * q
        }
        var added = false
        for (a, b) in runs.filter({ Double($0.1 - $0.0 + 1) * frame >= 0.6 }).prefix(3) {
            let lo = Int(max(0, Double(edge(a, -1)) * frame - 0.2) * 16000), hi = Int(min(dur, Double(edge(b, 1) + 1) * frame + 0.25) * 16000)
            guard hi - lo >= 9600 else { continue }
            let t0 = Double(lo) / 16000, t1 = Double(hi) / 16000
            let around = raw.filter { $0.t1 > t0 && $0.t0 < t1 }
            // a segment there with words of the other language in it heard this speech, if poorly: nothing was left out
            if r.lang == major, around.contains(where: { minor == "en" ? latinWord($0.text) : hangulWord($0.text) }) { continue }
            if env["LECTURE_DEBUG"] == "1" { log(String(format: "whisper: checking %.1f–%.1f s for left-out speech", t0, t1)) }
            let x = decode(Array(pcm[lo..<hi]), language: "auto", beam: 5)
            guard !x.text.isEmpty, x.conf > -0.9, !similar(x.text, r.text) else { continue }
            // the other language only when Whisper is sure of it: real English quotes measure 0.98–1.00, while Korean the
            // transcript already has (a slow speaker makes the guess of where a segment began too late) misidentified as
            // English measures 0.24–0.62 and comes out as invented English ("여러분," → "You're a good one.")
            let quote = x.lang == minor && x.sure >= 0.9 && written(x.text, in: minor)
            let ownGap = x.lang == major && !written(x.text, in: minor) && around.isEmpty    // a gap in Whisper's own timing
            guard quote || ownGap else { continue }
            parts.append((t0 - 0.01, t1, x.text))                                    // before what follows it
            added = true
            log("whisper: put back speech the transcript had left out")
        }
        guard added else { return r }
        var out = r
        out.parts = parts.sorted { $0.t0 < $1.t0 }
        out.text = clean(out.parts.map(\.text).joined(separator: " "))
        return out
    }

    /// Roughly how long `text` takes to say (`rate` syllables, half as many English words or 4 digits a second).
    private func spokenLength(_ text: String, rate: Double = 6) -> Double {
        var syllables = 0, digits = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0xAC00...0xD7A3, 0x3040...0x30FF, 0x4E00...0x9FFF: syllables += 1     // Hangul, kana, CJK (Whisper writes those too)
            case 0x30...0x39: digits += 1
            default: break
            }
        }
        return Double(syllables) / rate + Double(latinRuns(text).count) / (rate / 2) + Double(digits) / 4 + 0.2
    }

    /// The English words in `text`, also where a Korean particle is attached ("cost입니다").
    private func latinRuns(_ text: String) -> [String] {
        var runs: [String] = [], run = ""
        for ch in text + " " {
            if ch.isASCII && ch.isLetter { run.append(ch) } else if !run.isEmpty { runs.append(run); run = "" }
        }
        return runs
    }

    /// A Korean word (two syllables or more).
    private func hangulWord(_ text: String) -> Bool {
        var run = 0
        for u in text.unicodeScalars {
            if (0xAC00...0xD7A3).contains(u.value) { run += 1; if run >= 2 { return true } } else { run = 0 }
        }
        return false
    }

    /// An English word (four letters or more, not an acronym like "GDP").
    private func latinWord(_ text: String) -> Bool {
        latinRuns(text).contains { $0.count >= 4 && $0.contains { $0.isLowercase } }
    }

    /// Most of `a` (its letter pairs) already appears in `b`.
    private func similar(_ a: String, _ b: String) -> Bool {
        func pairs(_ s: String) -> [String] {
            let c = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
            return c.count < 2 ? c.map(String.init) : (0..<(c.count - 1)).map { String(c[$0...$0 + 1]) }
        }
        let pa = pairs(a), pb = Set(pairs(b))
        return !pa.isEmpty && Double(pa.filter(pb.contains).count) >= 0.6 * Double(pa.count)
    }

    /// Qwen3-ASR and Parakeet. Parakeet knows only English. Qwen3 identifies each piece's language itself and then
    /// writes both languages as spoken — told the language instead, it drops or spells out in Hangul the English words
    /// of a Korean piece. But it decides once per piece, and a piece it takes for the other language can come out
    /// translated ("다음 표현을 들어보세요. Actions speak…" → "Next, listen to the following. Actions speak…"), and
    /// an English term inside a Korean sentence is now and then left out ("말씀하신 는 공유지의 비극"). Both happen
    /// to pieces holding two utterances and depend on where the piece was cut, so such a piece is read again in two
    /// halves, split at its longest pause — and the halves are kept only if they bring back words of the missing
    /// language (a correct reading cut in a word can come out worse). Previews (`voice` empty) are read once.
    private func transcribeOther(_ pcm: [Float], voice: [Float], depth: Int = 0) -> String {
        let only = spec.languages.count == 1 ? spec.languages[0] : nil
        let r = run(pcm, language: only)
        guard only == nil, !r.text.isEmpty else { return r.text }
        // A third language (or kana / Chinese characters) is read again in the lecture's language — noise and accents make
        // Qwen3 name any language (kept as it was, noisy English came out in Thai script). In an English lecture a piece
        // Qwen3 itself took for Japanese or Chinese is read as Korean — in these lectures it is almost always a Korean
        // aside ("クラン継続かけます。" for "그럼 계속하겠습니다.", "苏哲，内伊卡金内。" for "숙제 내일까지 내."; told English it came
        // out translated or invented: "Then, we will continue.", "Such a nail, a jine.") — unless it is katakana alone,
        // English the way Japanese writes loanwords ("ハッピーバースデー。", which read as Korean became "하피 버스 데이").
        // (Japanese speech itself — a quote, a filler — comes out as Korean that way.)
        if foreign(r.text) || !["ko", "en"].contains(r.lang) {
            let katakanaOnly = !r.text.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
            if major == "en", !["ko", "en"].contains(r.lang), foreign(r.text), !katakanaOnly {
                let k = run(pcm, language: "ko")
                if !k.text.isEmpty { return k.text }
            }
            let m = run(pcm, language: major)
            return m.text.isEmpty ? r.text : m.text
        }
        guard !voice.isEmpty, depth < 2 else { return r.text }
        var doubt: String?, cut: (([Float], [Float]), ([Float], [Float]))?
        let other = r.lang == "ko" ? "en" : "ko"
        var want = other                                              // the script the halves must bring back
        if r.lang == "ko", strandedParticle(r.text), let h = halves(pcm, voice, pause: 0) {
            doubt = "may have left out a word"; cut = h; want = "en"   // a sure sign: cut even where the pause is short
        } else if !written(r.text, in: other, atAll: true), let h = halves(pcm, voice, pause: 5),
                  sentence(run(pcm, language: other).text, in: other) {
            // all in one language, but told the other one Qwen3 hears a sentence of it: translated or left out.
            // (Its reading in the other language is never used itself: told Korean, it turns "Time is money." into
            // "타임은 돈이다".)
            doubt = r.lang == minor ? "may have been translated" : "may have left out the other language"; cut = h
        }
        guard let doubt, let (left, right) = cut else { return r.text }
        if env["LECTURE_DEBUG"] == "1" { log("\(spec.id): a piece \(doubt); reading it again in two halves") }
        var a = transcribeOther(left.0, voice: left.1, depth: depth + 1)
        let b = transcribeOther(right.0, voice: right.1, depth: depth + 1)
        if env["LECTURE_DEBUG"] == "1" { log("\(spec.id):   halves: [\(a)] [\(b)]") }
        // the cut is mid-sentence more often than not: no full stop after a Korean word that doesn't end a sentence
        if a.range(of: "[가-힣]\\.$", options: .regularExpression) != nil,
           a.range(of: "(다|요|죠|까|네|지|음|함)\\.$", options: .regularExpression) == nil { a.removeLast() }
        let joined = [a, b].filter { !$0.isEmpty }.joined(separator: " ")
        // Kept only if the halves bring back what was missing. Korean added with every English word kept (casual endings
        // too: "수박 주스 꼭 메모해 둬"), or in place of English — often the first reading's translation of the aside ("This is
        // what comes up in the exam" → "이건 시험에 나옵니다.") — only as a clear Korean sentence: a formal ending, or two
        // words with particles. Told Korean, Qwen3 spells English out ("룩 에터 판다.", "굿모닝 에브리원", and "파파야" ends
        // like "사과야"). English left out of a Korean reading: added, or in place of about as many Hangul words (a quote
        // first spelled out: "프레티스 메이스 퍼펙트" → "Practice makes perfect"); in an English lecture, in place of a Korean
        // reading of English speech.
        let gain = words(joined, in: want) - words(r.text, in: want)
        let loss = words(r.text, in: r.lang) - words(joined, in: r.lang)
        let recovered = want == "ko"
            ? gain > 0 && (loss <= 0 || koreanSentence(joined))
            : gain > 0 && (r.lang == minor || loss <= gain + 1)
        guard recovered else {
            if env["LECTURE_DEBUG"] == "1" { log("\(spec.id):   the halves brought nothing back; kept the first reading") }
            return r.text
        }
        return joined
    }

    /// A clear Korean sentence: a formal ending (니다 요 죠 까) or two words with particles — not one word that happens to
    /// end like one ("파파야", "히말라야").
    private func koreanSentence(_ text: String) -> Bool {
        if text.range(of: "[가-힣](니다|요|죠|까)[.,?!]?(\\s|$)", options: .regularExpression) != nil { return true }
        let marked = try? NSRegularExpression(pattern: "[가-힣](은|는|을|를|에|에서|에게|께|한테|야)[.,?!]?(?=\\s|$)")
        return (marked?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0) >= 2
    }

    /// English words (2+ letters) or Korean words (2+ syllables) in `text`.
    private func words(_ text: String, in lang: String) -> Int {
        if lang == "en" { return latinRuns(text).filter { $0.count >= 2 }.count }
        return text.split(whereSeparator: { !(0xAC00...0xD7A3).contains($0.unicodeScalars.first!.value) }).filter { $0.count >= 2 }.count
    }


    /// Two utterances: the piece cut in the middle of its longest pause (at least `pause` frames of 32 ms by the voice
    /// detector; 0: its quietest moment) with at least half a second of speech on either side, each half with its
    /// voice frames. Nil for a single utterance.
    private func halves(_ pcm: [Float], _ voice: [Float], pause: Int) -> (([Float], [Float]), ([Float], [Float]))? {
        let need = Int(0.5 / frameSec)
        var before = [Int](repeating: 0, count: voice.count + 1)          // frames of speech before each frame
        for (i, p) in voice.enumerated() { before[i + 1] = before[i] + (p >= startP ? 1 : 0) }
        func inside(_ i: Int) -> Bool { before[i] >= need && before[voice.count] - before[i] >= need }   // not the edges' silence
        var pauseAt = -1, longest = 0, run = 0, quietAt = -1, quietest = Float.infinity
        for (i, p) in voice.enumerated() {
            if p < endP { run += 1; if run > longest, inside(i - run / 2) { longest = run; pauseAt = i - run / 2 } } else { run = 0 }
            if p < quietest, inside(i) { quietest = p; quietAt = i }
        }
        let best = longest >= max(pause, 1) ? pauseAt : pause == 0 ? quietAt : -1
        guard best > 0 else { return nil }
        let at = min(pcm.count, best * 512)
        return ((Array(pcm[..<at]), Array(voice[..<best])), (Array(pcm[at...]), Array(voice[best...])))
    }

    /// Kana or Chinese characters: neither language of a lecture here.
    private func foreign(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    /// Any word in the script of `lang`.
    private func written(_ text: String, in lang: String, atAll: Bool) -> Bool {
        lang == "en" ? latinRuns(text).contains { $0.count >= 2 } : hangulWord(text)
    }

    /// Speech of `lang` worth a second look: three English words, or Korean — a sentence ending or two words of two
    /// syllables ("출석 단어는 사과." has no ending). English spelled out in Hangul passes too; the halves then decide.
    private func sentence(_ text: String, in lang: String) -> Bool {
        if lang == "en" { return latinRuns(text).filter { $0.count >= 2 }.count >= 3 }
        return text.range(of: "[가-힣]{2,}(다|요|죠|까)[.?!]?(\\s|$)", options: .regularExpression) != nil || words(text, in: "ko") >= 2
    }

    /// A Korean particle standing alone after a Korean word: the (English) word it belonged to was left out.
    /// (Not 이란/란: "미국과 이란 사이" is Iran.)
    private func strandedParticle(_ text: String) -> Bool {
        text.range(of: "[가-힣][.,]? (는|을|를|라는|이라는)( |[.,?!]|$)", options: .regularExpression) != nil
    }

    private func run(_ pcm: [Float], language: String?) -> (text: String, lang: String) {
        guard let session, !abort.value, !pcm.isEmpty else { return ("", "") }
        var rp = transcribe_run_params()
        transcribe_run_params_init(&rp)
        let t0 = Date()
        func go(_ lang: UnsafePointer<CChar>?) -> transcribe_status {
            rp.language = lang
            return pcm.withUnsafeBufferPointer { transcribe_run(session, $0.baseAddress, Int32($0.count), &rp) }
        }
        let rc = language.map { $0.withCString(go) } ?? go(nil)
        let took = Date().timeIntervalSince(t0)
        // a decode that started repeating itself or ran out of room still holds what came before
        guard rc == TRANSCRIBE_OK || rc == TRANSCRIBE_ERR_OUTPUT_REPETITION || rc == TRANSCRIBE_ERR_OUTPUT_TRUNCATED else {
            if !abort.value { log("\(spec.id): decode failed (\(String(cString: transcribe_status_string(Int32(rc.rawValue)))))") }
            return ("", "")
        }
        if rc != TRANSCRIBE_OK { log("\(spec.id): decode stopped early (\(String(cString: transcribe_status_string(Int32(rc.rawValue)))))") }
        let text = String(cString: transcribe_full_text(session)).trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = language ?? String(cString: transcribe_detected_language(session))
        if env["LECTURE_DEBUG"] == "1" {
            log(String(format: "\(spec.id): decoded %.1f s of audio in %.2f s (%@ → %@): %@", Double(pcm.count) / 16000, took,
                       language ?? "auto", lang, String(text.prefix(60))))
        }
        return (text, lang)
    }

    private func decode(_ pcm: [Float], language: String, beam: Int) -> Result {
        guard let ctx, !abort.value, !pcm.isEmpty else { return Result(text: "", conf: -9, lang: language) }
        var p = whisper_full_default_params(beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        p.n_threads = 4
        p.no_context = true
        p.print_progress = false; p.print_realtime = false; p.print_timestamps = false; p.print_special = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.temperature = 0
        p.temperature_inc = 0.2
        p.no_speech_thold = 0.6
        p.beam_search.beam_size = Int32(beam)
        p.greedy.best_of = 1
        p.abort_callback = { data in data.map { Unmanaged<AbortFlag>.fromOpaque($0).takeUnretainedValue().value } ?? false }
        p.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        let t0 = Date()
        detectedP.value = language == "auto" ? 0 : 1
        let rc: Int32 = language.withCString { lang in
            p.language = lang
            return pcm.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
        let took = Date().timeIntervalSince(t0)
        guard rc == 0 else {
            if !abort.value { log("whisper: decode failed (\(rc))") }
            return Result(text: "", conf: -9, lang: language)
        }
        let eot = whisper_token_eot(ctx)
        var kept: [String] = [], sum = 0.0, count = 0, parts: [(t0: Double, t1: Double, text: String)] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            let t = String(cString: whisper_full_get_segment_text(ctx, i)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            var s = 0.0, n = 0
            for j in 0..<whisper_full_n_tokens(ctx, i) {
                let d = whisper_full_get_token_data(ctx, i, j)
                if d.id < eot { s += Double(d.plog); n += 1 }
            }
            let avg = n > 0 ? s / Double(n) : 0
            if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.6, avg < -1.0 { continue }      // no speech after all
            kept.append(t); sum += s; count += n
            parts.append((Double(whisper_full_get_segment_t0(ctx, i)) / 100, Double(whisper_full_get_segment_t1(ctx, i)) / 100, t))
        }
        let lang = String(cString: whisper_lang_str(whisper_full_lang_id(ctx)))
        let text = clean(kept.joined(separator: " "))
        let conf = count > 0 ? sum / Double(count) : -9                              // nothing kept: the least confident
        if env["LECTURE_DEBUG"] == "1" {
            log(String(format: "whisper: decoded %.1f s of audio in %.2f s (%@ → %@, beam %d, conf %.2f): %@", Double(pcm.count) / 16000, took,
                       language, lang, beam, conf, String(text.prefix(60))))
        }
        return Result(text: text, conf: conf, lang: lang, parts: text.isEmpty ? [] : parts, sure: detectedP.value)
    }

    private func clean(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let norm = t.replacingOccurrences(of: "[\\s.,!?…·\\-~]+", with: "", options: .regularExpression)
        guard !norm.isEmpty else { return "" }
        for h in hallucinations where norm.hasPrefix(h) && norm.count <= h.count + 8 {
            log("whisper: dropped a known hallucination")
            return ""
        }
        return t
    }
}
#endif
