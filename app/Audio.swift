// Audio sources for 강의 받아쓰기 v2. Every source delivers 16 kHz mono Int16 PCM — the format
// Apple's SpeechAnalyzer asks for — through a callback, from its own queue.

import AVFoundation
import AudioToolbox
#if os(macOS)
import CoreAudio
#else
import UIKit
#endif
import Foundation

let sampleRate = 16000.0
let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
private let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

protocol AudioSource: AnyObject {
    /// Called with 16 kHz mono Int16 buffers. `nil` means the source ended (files only).
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)? { get set }
    /// Something the user should know mid-recording: (notice code, message). Any thread.
    var onProblem: ((String, String) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Float32 → Int16 (the analyzer's format) without allocating a converter per buffer.
func int16Buffer(from f: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let n = Int(f.frameLength)
    guard n > 0, let src = f.floatChannelData?[0],
          let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)) else { return nil }
    out.frameLength = AVAudioFrameCount(n)
    let dst = out.int16ChannelData![0]
    for i in 0..<n { dst[i] = Int16(max(-1, min(1, src[i])) * 32767) }
    return out
}

struct CaptureError: Error, CustomStringConvertible {
    let step: String, status: OSStatus
    var description: String { "\(step) (\(status))" }
}

#if os(macOS)
// MARK: - System audio (Core Audio process tap, macOS 14.2+)

private func readProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
}

/// macOS 26 sometimes keeps a tap running but fills it with silence while the lecture plays on — with AirPods, minutes
/// in (2026-10-13: the tap's exact silence crept from a few percent to all of it in eight minutes and the transcript
/// stopped; Apple's developer forums, thread 825780, report the same on a MacBook Air M2). Only a new tap brings the
/// sound back. This watches what the tap delivers for the failing tap's signs: 5 s of exact silence, or 6 pieces of it
/// (40 ms or longer) within 10 s — "heavy" when 40 % or more of those 10 s are exact silence (the failing tap went
/// 10 → 30 → 55 %), "light" otherwise (could be the lecture's own gaps). A lecture's pauses don't look like that: in
/// 80 minutes of earlier recordings, never more than 2 such pieces in 10 s and never 3 s of exact silence while it played.
struct TapWatch {
    enum Sign: CustomStringConvertible {
        case silent(Double)                     // exact silence for this long (s)
        case heavy(Int, Double), light(Int, Double)   // pieces of exact silence in 10 s, the share of those 10 s silent
        var severe: Bool { if case .light = self { return false }; return true }
        var description: String {
            switch self {
            case .silent(let s): String(format: "%.1f s of exact silence", s)
            case .heavy(let n, let f), .light(let n, let f): String(format: "%d pieces of exact silence in 10 s (%.0f %% silent)", n, f * 100)
            }
        }
    }
    private var run = 0.0                  // exact silence so far (s)
    private var clock = 0.0                // audio seen (s)
    private var pieces: [Double] = []      // when each silent piece of 40 ms or more ended, within the last 10 s
    private var slots = [(silent: Double, total: Double)](repeating: (0, 0), count: 20)   // the last 10 s, 0.5 s each
    private var slot = 0

    /// How much of the last 10 s was exact silence (0–1).
    var silentShare: Double {
        let total = slots.reduce(0) { $0 + $1.total }
        return total > 0 ? slots.reduce(0) { $0 + $1.silent } / total : 0
    }

    /// One buffer from the tap: all exact silence or not, and how long it is.
    mutating func add(silent: Bool, seconds: Double) -> Sign? {
        clock += seconds
        if slots[slot].total >= 0.5 { slot = (slot + 1) % slots.count; slots[slot] = (0, 0) }
        slots[slot].total += seconds
        if silent {
            slots[slot].silent += seconds
            run += seconds
            return run >= 5 ? .silent(run) : nil
        }
        if run >= 0.04 { pieces.append(clock) }
        run = 0
        pieces.removeAll { clock - $0 > 10 }
        guard pieces.count >= 6 else { return nil }
        let share = silentShare
        return share >= 0.4 ? .heavy(pieces.count, share) : .light(pieces.count, share)
    }

    mutating func reset() { self = TapWatch() }
}

/// Every sample exactly zero (−0 too): what the failing tap delivers. A playing lecture is never exactly zero for long.
private func allSilent(_ abl: UnsafePointer<AudioBufferList>) -> Bool {
    for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)) {
        guard let d = b.mData else { continue }
        let words = d.assumingMemoryBound(to: UInt32.self)
        for i in 0..<Int(b.mDataByteSize) / 4 where words[i] & 0x7fff_ffff != 0 { return false }
    }
    return true
}

/// Is another app playing sound right now (its output running)? Tells the failing tap from a paused lecture.
private func othersPlaying() -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
    let me = getpid()
    return ids.contains { id in
        var pid: pid_t = 0, running: UInt32 = 0
        return readProp(id, kAudioProcessPropertyPID, &pid) == noErr && pid != me
            && readProp(id, kAudioProcessPropertyIsRunningOutput, &running) == noErr && running != 0
    }
}

/// Everything this Mac plays (all apps), mixed to mono. No microphone; works with earphones.
/// A tap-only private aggregate device is used so AirPods never switch to headset mode.
/// Two queues: `control` makes, replaces and removes the tap (start, stop, an output change, a new tap, the stall
/// check) — Core Audio is never asked to stop a device from `ioQueue`, which its I/O thread waits on (IO blocks are
/// dispatched synchronously); `ioQueue` gets the audio and keeps the watch on it.
final class SystemAudioSource: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)?
    var onProblem: ((String, String) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)         // control (the converter too: set while no audio flows)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let control = DispatchQueue(label: "lecture.capture.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "lecture.capture", qos: .userInteractive)
    private var listening = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var stallTimer: DispatchSourceTimer?                    // control
    private var stallLadder = 0, stallNextAt: UInt64 = 0            // control
    private var stallSince: UInt64?                                 // control: since when the tap hands nothing over while sound plays
    private var testDead = SystemAudioSource.test.dead              // control
    /// Seconds to wait before another new tap after 0, 1, 2, 3, 4+ new taps in a row that didn't help; for a tap that
    /// hands nothing over, at most a minute (nothing is lost by making it again).
    private static let waits: [Double] = [0, 15, 60, 300, 600], stallWaits: [Double] = [0, 15, 60]
    private static var outputDeviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                                       mElement: kAudioObjectPropertyElementMain)

    deinit {                                   // safety net: never leave a tap or device behind
        stallTimer?.cancel()
        if let l = listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemAudioSource.outputDeviceAddress, control, l)
        }
        teardown(drain: false)                 // (deinit may run on ioQueue itself)
    }

    /// Start and stop run on the control queue, one after the other: a 정지 during start-up tears down
    /// whatever start created, instead of leaving the tap running after the save.
    func start() throws {
        try control.sync {
            try startLocked()
            startStallCheck()
        }
    }

    private func startLocked() throws {
        guard !stopped else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Arc 강의 받아쓰기"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        log("capture: creating tap")
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        log("capture: create tap → \(st)")
        guard st == noErr else { throw CaptureError(step: "create tap", status: st) }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Arc 강의 받아쓰기 Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        log("capture: aggregate device → \(st)")
        guard st == noErr else { teardown(); throw CaptureError(step: "create aggregate device", status: st) }

        var asbd = AudioStreamBasicDescription()
        st = readProp(tapID, kAudioTapPropertyFormat, &asbd)
        guard st == noErr, let inFormat = AVAudioFormat(streamDescription: &asbd),
              let conv = AVAudioConverter(from: inFormat, to: floatFormat) else {
            teardown(); throw CaptureError(step: "tap format", status: st)
        }
        log("capture: tap format \(asbd.mSampleRate) Hz × \(asbd.mChannelsPerFrame)")
        conv.downmix = true
        converter = conv
        callbacks = 0                                      // each tap logs its first callbacks

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input, inFormat)
        }
        guard st == noErr else { teardown(); throw CaptureError(step: "create IO proc", status: st) }
        st = AudioDeviceStart(aggID, procID)
        log("capture: start device → \(st)")
        guard st == noErr else { teardown(); throw CaptureError(step: "start device", status: st) }
        listenForDeviceChanges()
        if stopped { teardown() }                          // 정지 arrived while macOS was busy starting
    }

    private var callbacks = 0
    private var stopped = false

    // The watch on what the tap delivers (TapWatch) — ioQueue only, except where `control` resets it while no audio
    // flows. The "is anything playing?" question goes to its own queue so the audio never waits for it.
    private var watch = TapWatch()
    private let checkQueue = DispatchQueue(label: "lecture.capture.check", qos: .utility)
    private var checking = false, renewing = false     // a check is out; a new tap is asked for or being made
    private var lastCheck: UInt64 = 0                  // uptime (ns) of the last "is anything playing?"
    private var lastTap: UInt64 = 0                    // uptime (ns) the current tap was made (0: the first)
    private var heardSound = 0.0                       // seconds of sound this session: the watch acts only after 1 s
    private var userPaused = false                     // 일시정지: the session drops the audio, the watch rests
    private var trial: (until: Double, troubled: Bool, probe: Bool, lightSeen: Bool, forSilence: Bool)?   // a new tap's first 15 s
    private var probing = false                        // the new tap asked for is a probe (for a light sign)
    private var forSilence = false                     // … or for silence: if it wasn't needed, the next needs longer
    private var silentNeed = 5.0                       // seconds of exact silence that count as a sign (5, 10, 20)
    private var silentNeedSince: UInt64 = 0            // when it was last raised
    private var probeWait = 600.0                      // seconds between probes; doubles (to an hour) while light signs stay
    private var ladder = 0                             // new taps in a row that didn't help
    private var nextTapAt: UInt64 = 0                  // uptime: no new tap before this (grows with `ladder`)
    private var nextProbeAt: UInt64 = 0                // uptime: no new tap for a light sign before this
    private var severeSince: UInt64?                   // uptime: when the silence or heavy chop going on began
    private var cleanFor = 0.0                         // seconds of audio since the last sign
    private var told = false, soundSinceTold = 0.0     // the user was told the sound isn't coming in
    private var renewals = 0
    private var audioClock = 0.0                       // seconds of audio the tap delivered
    private var lastDelivery: UInt64 = 0               // uptime (ns) of the last buffer
    private var fillGap = false                        // after a new tap: the time the change took goes in as silence

    private func process(_ abl: UnsafePointer<AudioBufferList>, _ inFormat: AVAudioFormat) {
        guard !stopped else { return }
        callbacks += 1
        if callbacks == 1 || callbacks == 200 { log("capture: audio callback #\(callbacks)") }
        guard let conv = converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: abl, deallocator: nil),
              inBuf.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                         frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * sampleRate / inFormat.sampleRate) + 64)
        else { return }
        let seconds = Double(inBuf.frameLength) / inFormat.sampleRate, now = DispatchTime.now().uptimeNanoseconds
        if fillGap {                                    // a new tap: the moment the change took goes in as silence — never
            fillGap = false                             // idle time (nothing plays → no samples, and none are recorded)
            let gap = min(Double(now &- lastDelivery) / 1e9 - seconds, 5)
            if lastDelivery > 0, gap > 0.02, let quiet = silence(seconds: gap) { onBuffer?(quiet) }
        }
        lastDelivery = now
        let silent = Self.test.active ? Self.test.apply(abl, inFormat, at: audioClock, taps: renewals) : allSilent(abl)
        audioClock += seconds
        watchTap(silent: silent, seconds: seconds, now: now)
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let pcm = int16Buffer(from: out) { onBuffer?(pcm) }
    }

    /// Each buffer: the tap's signs of trouble, and what to do about them. Nothing happens before the session has
    /// heard sound (a first run without the permission gets zeros — the session's own notice covers that) or while
    /// it is paused. Silence or heavy chop while another app plays sound → a new tap, the waits growing (0, 15 s,
    /// 1, 5, 10 min) while new taps don't help; light chop (maybe the lecture's own gaps) → a probe at most every 10
    /// minutes, every hour at most while the gaps stay, off the waits and never a notice. Each new tap is judged on its
    /// first 15 s as a whole. The user is told only after 45 s of silence or heavy chop despite a new tap, and the
    /// notice goes once 2 s of sound came through.
    private func watchTap(silent: Bool, seconds: Double, now: UInt64) {
        var sign = watch.add(silent: silent, seconds: seconds)
        if case .silent(let s)? = sign, s < silentNeed { sign = nil }      // the lecture's own pauses can be long
        if silentNeed > 5, Double(now &- silentNeedSince) / 1e9 >= 1800 { silentNeed = 5 }
        let severe = sign?.severe == true
        if !silent { heardSound += seconds; if told { soundSinceTold += seconds } }
        cleanFor = severe ? 0 : cleanFor + seconds                 // seconds without silence or heavy chop
        if severe, !userPaused { severeSince = severeSince ?? now } else if cleanFor >= 10 { severeSince = nil }
        if cleanFor >= 300 { ladder = 0; nextTapAt = 0 }           // five clean minutes: start over
        if told, !userPaused, soundSinceTold >= 10, watch.silentShare < 0.25 { resumed() }
        if var t = trial {
            if severe { t.troubled = true } else if sign != nil { t.lightSeen = true }
            trial = t
            guard audioClock >= t.until else { return }
            trial = nil
            if t.probe { probeWait = t.lightSeen ? min(probeWait * 2, 3600) : 600 }
            if t.forSilence, !t.troubled { silentNeed = min(silentNeed * 2, 20); silentNeedSince = now }
            if t.troubled { silentNeed = 5 }
            if t.troubled {
                ladder += 1
                let wait = Self.waits[min(ladder, Self.waits.count - 1)]
                nextTapAt = now + UInt64(wait * 1e9)
                log("capture: new tap #\(renewals) didn't help — the next not before \(Int(wait)) s")
            } else {
                log("capture: new tap #\(renewals) " + (t.lightSeen ? "— the short gaps stay (the lecture's own?)" : "hears the sound"))
                ladder = 0
                nextTapAt = 0
            }
            return
        }
        guard let sign, heardSound >= 1, !userPaused, !checking, !renewing, Double(now &- lastCheck) / 1e9 >= 3 else { return }
        let due = now >= (severe ? nextTapAt : max(nextTapAt, nextProbeAt))
        let tell = severe && !told && ladder >= 1 && severeSince.map { Double(now &- $0) / 1e9 >= 45 } == true
        guard due || tell else { return }
        checking = true
        lastCheck = now
        let tap = lastTap
        checkQueue.async { [weak self] in
            let playing = Self.test.playing || othersPlaying()
            self?.ioQueue.async { self?.decide(after: sign, playing: playing, due: due, tell: tell, tap: tap) }
        }
    }

    private func decide(after sign: TapWatch.Sign, playing: Bool, due: Bool, tell: Bool, tap: UInt64) {
        checking = false
        guard playing, !stopped, !userPaused, trial == nil, !renewing, lastTap == tap else { return }   // nothing plays: a pause
        if tell { tellNotComingIn() }
        guard due else { return }
        if !sign.severe { nextProbeAt = DispatchTime.now().uptimeNanoseconds + UInt64(probeWait * 1e9) }
        probing = !sign.severe
        if case .silent = sign { forSilence = true } else { forSilence = false }
        renewing = true
        renewals += 1
        log("capture: \(sign) while another app plays sound → new tap #\(renewals)")
        control.async { [weak self] in self?.renew() }
    }

    private func tellNotComingIn() {
        guard !told, !stopped else { return }
        told = true
        soundSinceTold = 0
        log("capture: told the user the sound isn't coming in")
        onProblem?("capture_stopped", L("강의 소리가 들어오지 않습니다. 강의가 재생 중인데도 이 메시지가 계속 보이면 [정지]를 누른 뒤 다시 시작하십시오. 지금까지의 녹음은 저장됩니다.",
                                        "The lecture's sound isn't coming in. If the lecture is playing and this message stays, click Stop, then start again. Everything recorded so far will be saved."))
    }

    private func resumed() {
        guard told, !stopped else { return }
        told = false
        log("capture: told the user the sound is back")
        onProblem?("capture_resumed", L("녹음을 다시 이어서 진행합니다.", "Recording has resumed."))
    }

    /// 일시정지 / 계속 (any thread): the session drops the audio meanwhile, so the watch rests.
    func setUserPaused(_ on: Bool) {
        ioQueue.async {
            self.userPaused = on
            if on { self.trial = nil; self.severeSince = nil } else { self.lastDelivery = DispatchTime.now().uptimeNanoseconds }
        }
    }

    /// Tests, no sound needed: LECTURE_TEST_TAP_TONE=1 puts a tone in place of what the tap hears;
    /// LECTURE_TEST_TAP_SILENCE / LECTURE_TEST_TAP_CHOP=<from>-<to>,… (seconds of the tap's audio) make the tap fail as
    /// macOS's does — all silence, or 110 ms pieces of silence between bits of sound; LECTURE_TEST_PLAYING=1 answers
    /// "another app plays sound"; LECTURE_TEST_TAP_HEALS=<n> ends that failure once n new taps were made;
    /// LECTURE_TEST_TAP_DEAD=<n> makes the next n new taps deliver nothing.
    private struct TestTap {
        let tone = env["LECTURE_TEST_TAP_TONE"] == "1", playing = env["LECTURE_TEST_PLAYING"] == "1"
        let silence = TestTap.spans("LECTURE_TEST_TAP_SILENCE"), chop = TestTap.spans("LECTURE_TEST_TAP_CHOP")
        let dead = Int(env["LECTURE_TEST_TAP_DEAD"] ?? "") ?? 0, heals = Int(env["LECTURE_TEST_TAP_HEALS"] ?? "") ?? .max
        var active: Bool { tone || !silence.isEmpty || !chop.isEmpty }
        static func spans(_ key: String) -> [ClosedRange<Double>] {
            (env[key] ?? "").split(separator: ",").compactMap { s in
                let p = s.split(separator: "-").compactMap { Double($0) }
                return p.count == 2 && p[0] <= p[1] ? p[0]...p[1] : nil
            }
        }
        /// Rewrites the tap's buffer in place; true when it is (made) all silence.
        func apply(_ abl: UnsafePointer<AudioBufferList>, _ format: AVAudioFormat, at t: Double, taps: Int) -> Bool {
            let gone = taps < heals && (silence.contains { $0.contains(t) }
                                        || (chop.contains { $0.contains(t) } && t.truncatingRemainder(dividingBy: 0.13) < 0.11))
            let channels = format.isInterleaved ? Int(format.channelCount) : 1
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)) {
                guard let d = b.mData else { continue }
                let f = d.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(b.mDataByteSize) / 4 {
                    if gone { f[i] = 0 } else if tone { f[i] = Float(0.1 * sin(2 * .pi * 440 * (t + Double(i / channels) / format.sampleRate))) }
                }
            }
            return gone || (!tone && allSilent(abl))
        }
    }
    private static let test = TestTap()

    /// A new tap in place of the old (control).
    private func renew() {
        guard !stopped else { ioQueue.async { self.renewing = false }; return }
        teardown()
        remake()
    }

    /// Makes the tap again after a teardown and puts it on trial. If it fails to start or hands nothing over, the
    /// stall check tries again (control).
    private func remake() {
        let made = DispatchTime.now().uptimeNanoseconds
        ioQueue.sync {                                     // no audio flows now: watch the new tap afresh
            lastTap = made
            watch.reset()
            cleanFor = 0
            fillGap = true
            trial = (audioClock + 15, false, probing, false, forSilence)
            probing = false
            forSilence = false
            renewing = false
            soundSinceTold = 0                            // "resumed" needs sound from this tap
        }
        guard !stopped else { return }
        do {
            try startLocked()
            if testDead > 0, let p = procID { testDead -= 1; AudioDeviceStop(aggID, p); log("capture: test: this tap hands nothing over") }
        } catch {
            log("capture: new tap failed: \(error) — the stall check tries again")
        }
    }

    /// Every 5 s (control): a tap that hands nothing over at all — dead, or not made again — while another app plays
    /// sound is made again on the same growing waits (the first after two checks in a row: playback may just be
    /// starting), and after 30 s of that the user is told. The outage counts only while the session listens and sound
    /// plays, and it runs on across new taps until one hands sound over.
    private func startStallCheck() {
        guard stallTimer == nil, !stopped else { return }
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.stallCheck() }
        t.resume()
        stallTimer = t
    }

    private func stallCheck() {
        guard !stopped else { return }
        let (last, made, armed, paused) = ioQueue.sync { (lastDelivery, lastTap, heardSound >= 1, userPaused) }
        let now = DispatchTime.now().uptimeNanoseconds                                  // (after the read: no wrap)
        let quiet = Double(now &- max(last, made)) / 1e9
        if last > made, quiet < 10 {                                                    // this tap hands sound over —
            if Double(last &- made) / 1e9 >= 15 { stallSince = nil; stallLadder = 0 }   // for 15 s now: recovered
            return
        }
        guard armed, !paused, Self.test.playing || othersPlaying() else { stallSince = nil; return }   // nothing to hand over
        guard quiet >= 10 else { return }                                               // a new tap gets 10 s
        let since = stallSince ?? now
        stallSince = since
        let outage = Double(now &- since) / 1e9
        if outage >= 30 { ioQueue.sync { tellNotComingIn() } }
        guard outage >= 5, now >= stallNextAt else { return }
        stallLadder += 1
        let wait = Self.stallWaits[min(stallLadder, Self.stallWaits.count - 1)]
        stallNextAt = now + UInt64(wait * 1e9)
        log("capture: nothing from the tap for \(Int(quiet)) s while another app plays sound → new tap (the next not before \(Int(wait)) s)")
        ioQueue.sync { renewals += 1 }
        teardown()
        remake()
    }

    /// Switching speakers ↔ earphones changes the tap's format: rebuild the capture (control).
    private func listenForDeviceChanges() {
        guard !listening else { return }
        listening = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped, self.aggID != AudioObjectID(kAudioObjectUnknown) else { return }
            log("capture: output device changed → new tap")
            self.teardown()
            self.remake()
            if !self.stopped, self.aggID == AudioObjectID(kAudioObjectUnknown), self.ioQueue.sync(execute: { self.heardSound >= 1 }) {
                self.ioQueue.sync { self.told = true; self.soundSinceTold = 0 }
                self.onProblem?("capture_stopped", L("출력 장치가 바뀐 뒤 소리를 다시 가져오지 못했습니다. [정지]를 누른 뒤 다시 시작하십시오.", "Couldn't get the sound back after the output device changed. Click Stop, then start again."))
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemAudioSource.outputDeviceAddress, control, block)
    }

    /// Removes the tap and its device. `drain`: wait until no IO block is still running before the converter goes
    /// (control; never from ioQueue).
    private func teardown(drain: Bool = true) {
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            if let p = procID {
                AudioDeviceStop(aggID, p)
                if drain { ioQueue.sync {} }
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        converter = nil
    }

    /// Never blocks the caller: Core Audio calls can hang while macOS is busy with permissions.
    func stop() {
        stopped = true
        control.async { [self] in
            stallTimer?.cancel()
            stallTimer = nil
            if let l = listener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemAudioSource.outputDeviceAddress, control, l)
                listener = nil
            }
            teardown()
            log("capture: stopped")
        }
    }
}

#endif

#if os(iOS)
// MARK: - Microphone (iPhone/iPad)

/// The device microphone: a lecture playing nearby (laptop, TV) or in the room. Keeps recording with
/// the screen locked (background audio); pauses for calls and picks up again afterwards (also when iOS
/// never says the call ended: on return to the app); rebuilds itself after route changes or a
/// media-services reset; tells the user if it can't, and says so again when it recovers.
/// All engine work happens on the main thread, so start, stop and restarts never overlap.
final class MicAudioSource: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)?
    var onProblem: ((String, String) -> Void)?
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var running = false             // between start() and stop()
    private var stopRequested = false
    private var interrupted = false         // a call or another app has the audio session
    private var interruptedAt = Date.distantPast
    private var troubled = false            // a pause/stop notice is showing: say when it's fine again
    private var attempt = 0
    private var lastQuietTry = Date.distantPast
    private var retry: DispatchWorkItem?
    private var stallTimer: Timer?
    private var lastBuffer = Date()
    private let lock = NSLock()

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
    }

    func start() throws {
        if Thread.isMainThread { try startOnMain() } else { try DispatchQueue.main.sync { try startOnMain() } }
    }

    private func startOnMain() throws {
        guard !stopRequested else { return }
        try configureSession()
        try startEngine()
        running = true
        log("capture: microphone \(engine.inputNode.outputFormat(forBus: 0).sampleRate) Hz")
        let nc = NotificationCenter.default, session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                log("capture: interrupted")
                self.interrupted = true
                self.interruptedAt = Date()
                self.tell("capture_paused", L("전화나 다른 앱 때문에 녹음이 잠시 멈췄습니다. 끝나면 이어서 녹음합니다.", "Recording paused for a moment because of a call or another app. It will resume when that ends."))
            } else {
                log("capture: interruption ended, resuming")
                self.interrupted = false
                self.restart()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            log("capture: media services reset, rebuilding")
            guard let self, self.running else { return }
            self.engine = AVAudioEngine()                      // the old engine is dead: just let it go
            self.restart()
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            if !self.interrupted { if self.attempt >= 4 { self.restart() }; return }             // gave up earlier: try again now
            guard (try? self.configureSession()) != nil else { return }                          // still in a call
            log("capture: back in the app while paused, resuming")  // iOS doesn't always send "ended"
            self.interrupted = false
            self.restart()
        })
        stallTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkStall() }
        if stopRequested { stopOnMain() }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0, let conv = AVAudioConverter(from: fmt, to: floatFormat) else {
            throw CaptureError(step: "microphone", status: -1)
        }
        conv.downmix = true
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in self?.process(buf) }
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            log("capture: audio route changed")
            self?.restart()
        }
        engine.prepare()
        try engine.start()
        lock.lock(); lastBuffer = Date(); lock.unlock()
    }

    private func tell(_ code: String, _ msg: String) {
        troubled = code != "capture_resumed"
        onProblem?(code, msg)
    }

    /// Restart the engine (route change, end of a call, stall). One retry chain at a time: 1, 3, 10 s.
    private func restart() {
        guard running, !interrupted else { return }
        retry?.cancel(); retry = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try configureSession()
            try startEngine()
            attempt = 0
            if troubled { tell("capture_resumed", L("녹음을 다시 이어서 진행합니다.", "Recording has resumed.")) }
        } catch {
            attempt += 1
            log("capture: restart failed (\(attempt)): \(error)")
            if attempt <= 3 {
                let work = DispatchWorkItem { [weak self] in self?.restart() }
                retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + [1.0, 3.0, 10.0][attempt - 1], execute: work)
            } else if attempt == 4 {
                lastQuietTry = Date()
                tell("capture_stopped", L("마이크 녹음이 멈췄습니다. [정지]를 누른 뒤 다시 시작하십시오. 지금까지의 녹음은 저장됩니다.", "Microphone recording stopped. Tap Stop, then start again. Everything recorded so far will be saved."))
            }
        }
    }

    private func checkStall() {
        guard running else { return }
        if interrupted {                     // a pause iOS never ended: once a minute, see if the audio is free again
            if Date().timeIntervalSince(interruptedAt) > 60 {
                interruptedAt = Date()
                if (try? configureSession()) != nil { interrupted = false; restart() }   // still in a call: stays paused, quietly
            }
            return
        }
        if attempt >= 4 {                    // gave up and said so: keep trying quietly (e.g. the call finally ended)
            if Date().timeIntervalSince(lastQuietTry) > 30 { lastQuietTry = Date(); restart() }
            return
        }
        guard retry == nil else { return }
        lock.lock(); let quiet = Date().timeIntervalSince(lastBuffer); lock.unlock()
        if quiet > 6 {
            log("capture: no buffers for \(Int(quiet)) s, restarting")
            restart()
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        lock.lock(); lastBuffer = Date(); lock.unlock()
        guard let conv = converter, buf.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * sampleRate / buf.format.sampleRate) + 64)
        else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let pcm = int16Buffer(from: out) { onBuffer?(pcm) }
    }

    func stop() {
        if Thread.isMainThread { stopOnMain() } else { DispatchQueue.main.async { self.stopOnMain() } }
    }

    private func stopOnMain() {
        stopRequested = true
        guard running else { return }
        running = false
        retry?.cancel(); retry = nil
        stallTimer?.invalidate(); stallTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let o = engineObserver { NotificationCenter.default.removeObserver(o); engineObserver = nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

// MARK: - Files (any audio/video AVFoundation can read)

/// Decodes a media file. `realtime` paces delivery like live audio (used by silent tests);
/// otherwise it runs as fast as the decoder can.
final class FileAudioSource: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer?) -> Void)?
    var onProblem: ((String, String) -> Void)?
    let url: URL
    let realtime: Bool
    private(set) var duration: Double = 0
    private var cancelled = false
    private var reader: AVAssetReader?          // must outlive the read loop (a freed reader raises, crashing the app)
    private let queue = DispatchQueue(label: "lecture.file", qos: .userInitiated)

    init(url: URL, realtime: Bool = false) {
        self.url = url
        self.realtime = realtime
    }

    func start() throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])   // VBR mp3: real length
        let sem = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        var loadedDuration = CMTime.zero
        Task {
            tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            var audioEnd = 0.0                                 // the sound's own length, not the video's
            for t in tracks { if let r = try? await t.load(.timeRange), r.end.seconds.isFinite { audioEnd = max(audioEnd, r.end.seconds) } }
            loadedDuration = audioEnd > 0 ? CMTime(seconds: audioEnd, preferredTimescale: 600) : ((try? await asset.load(.duration)) ?? .zero)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut {      // a hung network drive, an iCloud file still downloading
            if cancelled { return }                            // 정지 already ended this session: stay quiet
            throw CaptureError(step: "file took too long to open", status: -3)
        }
        guard !cancelled else { return }
        guard !tracks.isEmpty else { throw CaptureError(step: "no audio track", status: -1) }
        duration = loadedDuration.seconds.isFinite ? loadedDuration.seconds : 0
        let reader = try AVAssetReader(asset: asset)
        self.reader = reader
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw CaptureError(step: "read file", status: -2) }
        queue.async { [weak self, reader, output] in
            let t0 = Date()
            var sent = 0
            while let self, !self.cancelled, reader.status == .reading, let sb = output.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                let bytes = CMBlockBufferGetDataLength(bb)
                let frames = bytes / 2
                guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: buf.int16ChannelData![0])
                self.onBuffer?(buf)
                sent += frames
                if self.realtime {
                    let ahead = Double(sent) / sampleRate - Date().timeIntervalSince(t0)
                    if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
                }
            }
            let got = Double(sent) / sampleRate
            if reader.status == .failed {
                log("file read failed: \(String(describing: reader.error))")
                self?.onProblem?("file_error", got > 1 ? L("파일을 끝까지 읽지 못했습니다. 파일이 손상되었을 수 있습니다 — 읽은 부분까지만 받아 적었습니다.", "Couldn't read the file to the end. It may be damaged — only the part that could be read was transcribed.")
                                                       : L("이 파일에서 소리를 읽을 수 없습니다. 파일이 손상되었을 수 있습니다.", "Can't read any sound from this file. It may be damaged."))
            } else if let me = self, !me.cancelled, me.duration > 5, got < me.duration * 0.9 {   // e.g. a WAV cut short
                log("file ended early: \(Int(got)) of \(Int(me.duration)) s")
                me.onProblem?("file_error", L("파일이 중간에 끊겨 있습니다 — 앞부분(\(fmtTime(got)))까지만 받아 적었습니다.", "The file is cut off partway — only the first part (\(fmtTime(got))) was transcribed."))
            }
            self?.onBuffer?(nil)
        }
    }

    func stop() { cancelled = true }
}
