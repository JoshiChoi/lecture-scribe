// Page ↔ app commands shared by the Mac and iPhone/iPad apps: the engine (recording), the session
// library and the player. Each app supplies the few things that differ through `Platform`.

import Foundation

@MainActor
protocol Platform: AnyObject {
    func copyText(_ text: String)
    func openFolder(_ url: URL)
    func reveal(_ url: URL)
    func share(_ urls: [URL], from rect: CGRect)
    func pickFile()
    func openPrivacy()
    /// Asks for whatever recording needs (iPhone: the microphone permission).
    func requestRecording(_ done: @escaping @MainActor (Bool) -> Void)
    /// Opens a document (the slide PDF) in the system viewer.
    func openDocument(_ url: URL)
    /// Mac: start/stop watching the lecture window for slides (frames go to engine.session). iPhone: nothing.
    func startScreenSlides()
    func stopScreenSlides()
    /// 설정: window colours for the page's theme; the app icon; a web link; the log folder (Mac).
    func applyAppearance(dark: Bool, system: Bool)
    func setAppIcon(_ name: String)
    func openLink(_ url: URL)
    func openLogs()
    /// The app's language changed: menus (Mac) and the page in the new one.
    func languageChanged()
    /// Mac: a System Settings page — "update" (Software Update), "speech" (Privacy › Speech Recognition).
    func openPane(_ name: String)
}

extension Platform {
    func openPane(_ name: String) {}
}

@MainActor
final class Bridge {
    private(set) var engine: Engine!
    let player = Player()
    weak var platform: Platform?
    private let send: ([String: Any]) -> Void
    private var deleted: [String: [Library.Deleted]] = [:]     // per id: the same name can be deleted twice

    init(send: @escaping ([String: Any]) -> Void) {
        self.send = send
        player.emit = send
        engine = Engine { [weak self] ev in self?.engineEvent(ev) }
        Task.detached(priority: .background) { Library.finalizeLeftovers() }
    }

    private func engineEvent(_ ev: [String: Any]) {
        send(ev)
        let name = ev["ev"] as? String, state = ev["state"] as? String
        if name == "saved" || name == "recovered" || (name == "rec" && state == "recording") { refreshLibrary() }
        if name == "rec", state == "finishing" || state == "idle" { platform?.stopScreenSlides() }
    }

    private var recordingID: String? { engine.session?.id }
    private var libraryGen = 0
    private var finalizeTask: Task<Void, Never>?

    /// Deleted sessions waiting for 되돌리기 go on to the Trash (Mac): 15 s after the last delete, or at quit.
    func finalizeDeletes() {
        finalizeTask?.cancel()
        for d in deleted.values.joined() { Library.finalize(d.bin) }
        deleted.removeAll()
    }

    private func scheduleFinalize() {
        finalizeTask?.cancel()
        finalizeTask = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { self.finalizeDeletes() }
        }
    }

    func refreshLibrary() {
        let dir = engine.outDir, kw = engine.keywords, rec = recordingID, busy = engine.busyIDs
        libraryGen += 1
        let gen = libraryGen
        Task.detached(priority: .userInitiated) {
            let list = Library.scan(dir, keywords: kw, recording: rec, busy: busy)
            await MainActor.run {
                guard gen == self.libraryGen else { return }              // a newer refresh is on its way
                self.send(["ev": "library", "sessions": list, "folder": dir.path])
            }
        }
    }

    private func notice(_ code: String, _ msg: String) { send(["ev": "notice", "code": code, "msg": msg]) }

    private func rect(_ body: [String: Any]) -> CGRect {
        func n(_ k: String) -> Double { (body[k] as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
    }

    func handle(_ cmd: String, _ body: [String: Any]) {
        let id = (body["id"] as? String)?.nfc
        let editable = id.map { !engine.busyIDs.contains($0) } ?? false     // not while recording or saving
        if !editable, id != nil, ["play", "rename", "delete", "share", "revealSession", "saveLines"].contains(cmd) {
            notice("busy_saving", id == recordingID ? L("지금 녹음 중인 기록입니다. 녹음을 마친 뒤에 다시 시도하십시오.", "This recording is still in progress. Try again once the recording has finished.")
                                                    : L("이 기록은 아직 저장하는 중입니다. 잠시 후에 다시 시도하십시오.", "This recording is still being saved. Try again in a moment."))
            if cmd == "rename", let id { send(["ev": "renamed", "from": id, "to": id]) }                // put the old name back
            return
        }
        switch cmd {
        case "ready": engine.pageLoaded()
        case "start":
            player.stop()
            platform?.requestRecording { [weak self] ok in
                guard let self else { return }
                guard ok else { self.notice("mic_denied", L("마이크 권한이 꺼져 있습니다.", "Microphone access is turned off.")); return }
                self.engine.start(.live)
                if self.engine.session != nil, self.engine.settings.slides { self.platform?.startScreenSlides() }
            }
        case "stop": engine.stop()
        case "pauseRec": engine.session?.setPaused(true)
        case "resumeRec": engine.session?.setPaused(false)
        case "retry": engine.retry()
        case "settings":
            let icon = engine.settings.icon, slides = engine.settings.slides, lang = engine.settings.uiLanguage
            engine.updateSettings(body)
            if engine.settings.uiLanguage != lang { player.pause(); platform?.languageChanged() }   // no sound left without its controls
            if body["keywords"] != nil { refreshLibrary() }
            if engine.settings.icon != icon { platform?.setAppIcon(engine.settings.icon) }
            if engine.settings.slides != slides {                                   // 슬라이드 PDF switched mid-recording
                if let s = engine.session {
                    if engine.settings.slides { if s.mode == .live { platform?.startScreenSlides() } }
                    else { platform?.stopScreenSlides(); s.dropSlides() }
                }
                if !engine.settings.slides { engine.dropSavingSlides() }             // …or while a file is still being finished
            }
        case "appearance": platform?.applyAppearance(dark: body["dark"] as? Bool ?? true, system: body["system"] as? Bool ?? false)
        case "engineSelect": engine.selectEngine(body["engine"] as? String ?? "")        // 설정 › 음성 인식
        case "engineDownload": engine.downloadEngine(body["engine"] as? String ?? "")
        case "engineCancel": engine.cancelEngine(body["engine"] as? String ?? "")
        case "engineRemove": engine.removeEngine(body["engine"] as? String ?? "")
        case "openLink":                                                      // only the project's own pages
            if let s = body["url"] as? String, let u = URL(string: s), u.scheme == "https", u.host == "github.com" { platform?.openLink(u) }
        case "openLogs": platform?.openLogs()
        case "storage":
            let dir = engine.outDir
            Task.detached(priority: .utility) {
                let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                let bytes = items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                let count = items.filter { $0.pathExtension == "txt" && Library.parse((try? String(contentsOf: $0, encoding: .utf8)) ?? "") != nil }.count
                await MainActor.run { self.send(["ev": "storage", "count": count, "bytes": bytes, "folder": dir.path]) }
            }
        case "copy":
            let text = body["text"] as? String ?? ""
            platform?.copyText(text)
            send(["ev": "copied", "chars": text.count])
        case "openFolder":
            try? FileManager.default.createDirectory(at: engine.outDir, withIntermediateDirectories: true)
            platform?.openFolder(engine.outDir)
        case "openFile", "reveal":                                         // a saved file, by path
            if let p = body["path"] as? String, FileManager.default.fileExists(atPath: p) { platform?.reveal(URL(fileURLWithPath: p)) }
        case "pickFile": platform?.pickFile()
        case "openPrivacy": platform?.openPrivacy()
        case "openPane": platform?.openPane(body["pane"] as? String ?? "")
        case "log": log("page: \(body["msg"] ?? "")")

        // ---- library
        case "library": refreshLibrary()
        case "session":
            guard let id else { return }
            let dir = engine.outDir, rec = recordingID, busy = engine.busyIDs
            Task.detached(priority: .userInitiated) {
                let s = Library.session(dir, id: id, recording: rec, busy: busy)
                await MainActor.run {
                    guard let s else {
                        self.notice("session_missing", L("이 기록을 찾을 수 없습니다. 파일이 옮겨졌거나 삭제되었을 수 있습니다.", "Can't find this recording. Its files may have been moved or deleted."))
                        self.refreshLibrary()
                        return
                    }
                    self.send(s)
                    if (s["audio"] as? Bool) == true, let a = Library.audioURL(dir, id) { self.player.load(id: id, url: a, title: id) }
                }
            }
        case "play":
            guard let id, editable else { return }
            if engine.session?.mode == .live {
                notice("busy_recording", L("녹음 중에는 재생할 수 없습니다. 녹음을 마친 뒤에 들으십시오.", "Playback isn't available while recording. Listen after the recording has finished."))
                return
            }
            if player.id != id {
                guard let a = Library.audioURL(engine.outDir, id) else { return }
                player.load(id: id, url: a, title: id)
            }
            player.play(at: (body["t"] as? NSNumber)?.doubleValue)
        case "pause": player.pause()
        case "seek": if let t = (body["t"] as? NSNumber)?.doubleValue { player.seek(t) }
        case "skip": if let d = (body["d"] as? NSNumber)?.doubleValue { player.skip(d) }
        case "rate": if let r = (body["r"] as? NSNumber)?.floatValue { player.setRate(r) }
        case "rename":
            guard let id, let name = body["name"] as? String, editable else { return }
            do {                                              // an open recording keeps playing: its file stays open
                let new = try Library.rename(engine.outDir, id: id, to: name)
                player.renamed(from: id, to: new)
                send(["ev": "renamed", "from": id, "to": new])
                refreshLibrary()
            } catch Library.Problem.exists {
                notice("rename", L("같은 이름의 기록이 이미 있습니다.", "A recording with that name already exists."))
                send(["ev": "renamed", "from": id, "to": id])
            } catch {
                notice("rename", L("이름을 변경하지 못했습니다.", "Couldn't rename the recording."))
                send(["ev": "renamed", "from": id, "to": id])
            }
        case "saveLines":                                     // 글 편집: the page sends every line as it is now
            guard let id, editable, let rows = body["lines"] as? [[Any]] else { return }
            let lines = rows.compactMap { row -> Library.Line? in
                guard row.count == 2, let t = (row[0] as? NSNumber)?.doubleValue, let s = row[1] as? String else { return nil }
                let text = s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : Library.Line(t: max(0, t), text: text)
            }
            do {
                try Library.writeLines(engine.outDir, id: id, lines: lines, keywords: engine.keywords)
                send(["ev": "linesSaved", "id": id, "count": lines.count])
                refreshLibrary()
            } catch {
                log("edit failed: \(error)")
                notice("edit", L("고친 내용을 저장하지 못했습니다.", "Couldn't save your changes."))
                send(["ev": "linesSaved", "id": id, "failed": true])
            }
        case "delete":
            guard let id, editable else { return }
            if player.id == id { player.stop() }
            do {
                deleted[id, default: []].append(try Library.delete(engine.outDir, id: id))
                send(["ev": "deleted", "id": id])
                scheduleFinalize()
            } catch {
                log("delete failed: \(error)")
                notice("delete", L("기록을 삭제하지 못했습니다.", "Couldn't delete the recording."))
            }
            refreshLibrary()
        case "undoDelete":
            guard let id, var stack = deleted[id], let d = stack.popLast() else { return }
            deleted[id] = stack.isEmpty ? nil : stack
            do {
                let back = try Library.undo(d)
                send(["ev": "restored", "id": back, "from": id])
            } catch {
                log("undo failed: \(error)")
                Library.finalize(d.bin)                                    // Mac: still recoverable from the Trash
                #if os(macOS)
                notice("undo", L("되돌리지 못했습니다. Finder의 휴지통에서 꺼낼 수 있습니다.", "Couldn't undo. You can restore it from the Trash in Finder."))
                #else
                notice("undo", L("되돌리지 못했습니다.", "Couldn't undo."))
                #endif
            }
            refreshLibrary()
        case "share":
            guard let id, editable else { return }
            let urls = Library.files(engine.outDir, id).filter { $0.pathExtension != "wav" || Library.audioURL(engine.outDir, id) == $0 }
            if !urls.isEmpty { platform?.share(urls, from: rect(body)) }
        case "openSlides":
            guard let id else { return }
            let pdf = engine.outDir.appendingPathComponent("\(id).pdf")
            if FileManager.default.fileExists(atPath: pdf.path) { platform?.openDocument(pdf) }
            else { notice("slides_missing", L("슬라이드 PDF를 찾을 수 없습니다.", "Can't find the Slide PDF.")) }
        case "revealSession":
            guard let id, editable else { return }
            if let f = Library.files(engine.outDir, id).first { platform?.reveal(f) }
        default: break
        }
    }
}
