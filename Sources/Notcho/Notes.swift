import Foundation

// MARK: - Files in iCloud Drive → Notch (Notes/2026-10-28.md, Plans/<Project>.md)

enum NoteFiles {
    /// iCloud Drive so the Files app on the iPhone sees them; ~/Documents/Notch if iCloud Drive is off.
    static let root: URL = {
        let icloud = URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: icloud.path(percentEncoded: false)) ? icloud.appending(path: "Notch")
                                                                     : URL.documentsDirectory.appending(path: "Notch")
    }()
    static var notesDir: URL { root.appending(path: "Notes") }
    static var plansDir: URL { root.appending(path: "Plans") }

    static func noteURL(_ day: Date) -> URL { notesDir.appending(path: isoDay(of: day) + ".md") }

    /// "Eye for Design / Site" → "Eye for Design - Site.md"
    static func planURL(_ project: Project) -> URL {
        let safe = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return plansDir.appending(path: safe + ".md")
    }

    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private static let writer = DispatchQueue(label: "notch.notes.writer")

    /// Background, atomic. Empty text for a file that doesn't exist yet writes nothing.
    static func write(_ text: String, to url: URL) {
        writer.async {
            if text.isEmpty && !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func flush() { writer.sync {} }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// Dated notes, newest first.
    static func listNotes() -> [(day: String, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
            .sorted { $0.0 > $1.0 }
    }
}

// MARK: - The notch Notepad is today's note

/// Keeps `store.notes` and today's dated file in step: notch edits write the file; a new day starts a fresh note;
/// edits made elsewhere (Files app, another Mac, an agent) are pulled back in.
final class DailyNotes {
    static let shared = DailyNotes()
    weak var store: Store?
    private let dayKey = "notes.day"
    private var pending: DispatchWorkItem?
    private var lastWrite = Date.distantPast
    private var applying = false

    func start(_ store: Store) {
        self.store = store
        let today = isoDay(of: store.today)
        if UserDefaults.standard.string(forKey: dayKey) == nil {
            // One-time move: the old single Notepad becomes today's note (kept if a note for today already exists).
            let url = NoteFiles.noteURL(store.today)
            if NoteFiles.read(url) == nil { NoteFiles.write(store.notes, to: url); lastWrite = .now }
            UserDefaults.standard.set(today, forKey: dayKey)
        }
        store.onNotesChanged = { [weak self] in self?.notesChanged() }
        tick()
    }

    private func notesChanged() {
        guard !applying, let store else { return }
        pending?.cancel()
        let text = store.notes, url = NoteFiles.noteURL(store.today)
        let work = DispatchWorkItem { [weak self] in NoteFiles.write(text, to: url); self?.lastWrite = .now }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Once a minute: start a fresh note on a new day, and pick up outside edits to today's.
    func tick() {
        guard let store else { return }
        let today = isoDay(of: store.today), url = NoteFiles.noteURL(store.today)
        if UserDefaults.standard.string(forKey: dayKey) != today {
            pending?.perform() // finish writing yesterday's note first
            UserDefaults.standard.set(today, forKey: dayKey)
            set(NoteFiles.read(url) ?? "")
            return
        }
        if let changed = NoteFiles.modified(url), changed > lastWrite.addingTimeInterval(2),
           let text = NoteFiles.read(url), text != store.notes {
            set(text)
        }
    }

    /// Adds a line to today's note (daily wrap-up highlights).
    func append(_ text: String) {
        guard let store else { return }
        store.notes = store.notes.isEmpty ? text : store.notes + "\n\n" + text
    }

    private func set(_ text: String) {
        applying = true; store?.notes = text; applying = false
    }
}
