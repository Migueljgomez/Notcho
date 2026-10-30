import AppKit
import Observation
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Fridge: files stuck to the notch as magnets
// Each item links to the original file (a bookmark), so nothing is copied unless you Keep it.
// Keep copies the file to iCloud Drive › Notch › Fridge and pins it, so it never slides off.
// Saved in its own fridge.json, never in store.json.

/// New fields must be optional: fridge.json uses synthesized Codable.
struct FridgeItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bookmark: Data?      // link to the original file
    var text: String?        // dropped text lives here instead of in a file
    var keptPath: String?    // the copy in iCloud Drive › Notch › Fridge
    var tilt: Double         // degrees, so each magnet sits a little crooked
    var magnet: Int          // index into Fridge.magnets
    var addedAt: Date
    var kept: Bool { keptPath != nil }
}

@Observable final class Fridge {
    static let shared = Fridge(file: URL.applicationSupportDirectory.appending(path: "Notcho/fridge.json"))
    static let limit = 12
    static let magnets = [0xE5484D, 0x0A64D8, 0x30A46C, 0xF5A524, 0x8E4EC6]
    static var keptDir: URL { NoteFiles.root.appending(path: "Fridge") }
    static let dropsDir = URL.applicationSupportDirectory.appending(path: "Notcho/Fridge Drops") // images dropped without a file
    static let dropTypes: [UTType] = [.fileURL, .image, .url, .plainText]

    private(set) var items: [FridgeItem] = []                // newest first
    private(set) var urls: [UUID: URL] = [:]                 // where each item opens; a missing original has none
    private(set) var info: [UUID: String] = [:]              // "PDF · 84 KB"
    private(set) var thumbs: [UUID: NSImage] = [:]           // image previews for the polaroids
    private(set) var undo: (added: UUID, slid: FridgeItem, at: Int)?
    private(set) var cleared: [FridgeItem]?                  // what Clear Fridge took off, until Undo times out
    private(set) var full = false                            // a drop was refused because every item is kept
    @ObservationIgnored let file: URL
    @ObservationIgnored private var notice = 0

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        if let saved = try? JSONDecoder().decode([FridgeItem].self, from: data) { items = saved; refresh() }
        else { // never overwrite a file we can't read: set it aside and start empty
            try? FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appending(path: "fridge.unreadable-\(Int(Date.now.timeIntervalSince1970)).json"))
        }
    }

    // MARK: Rules (pure, self-tested)

    /// Puts `item` first. Past `limit` the oldest unkept item slides off (with where it was, for Undo).
    /// nil when every other item is kept: the fridge is full.
    static func adding(_ item: FridgeItem, to items: [FridgeItem], limit: Int = limit) -> (items: [FridgeItem], slid: (FridgeItem, Int)?)? {
        var list = [item] + items
        guard list.count > limit else { return (list, nil) }
        guard let i = list.lastIndex(where: { !$0.kept && $0.id != item.id }) else { return nil }
        let slid = list.remove(at: i)
        return (list, (slid, i - 1))
    }

    /// Magnet centers for a `w` × `h` card in reading order, and their scale. Every magnet stays on one door,
    /// clear of the seam at w / 2. Narrow cards get one small magnet per door; wide ones two per door on the top row.
    static func spots(w: CGFloat, h: CGFloat) -> (points: [CGPoint], scale: CGFloat) {
        let small = w < 200, scale: CGFloat = small ? 0.72 : 1
        let half = 40 * scale, step: CGFloat = small ? 76 : 104
        var points: [CGPoint] = [], y: CGFloat = small ? 98 : 108, row = 0
        while y + half <= h - 40 { // the bottom 40 pt keep room for "+N more"
            let perDoor = w >= 400 && row == 0 ? 2 : 1
            for door in 0..<2 {
                for c in 0..<perDoor {
                    let x = CGFloat(door) * w / 2 + (CGFloat(c) + 0.5) * w / 2 / CGFloat(perDoor)
                    points.append(CGPoint(x: x, y: y + (door == 0 ? 0 : 2))) // a touch uneven, like real magnets
                }
            }
            y += step; row += 1
        }
        return (points, scale)
    }

    // MARK: Adding

    func add(file url: URL, keep: Bool = false) {
        let path = url.standardizedFileURL.path(percentEncoded: false) // already on the door (or dragged back onto it): bring it forward
        if let old = items.first(where: { urls[$0.id]?.standardizedFileURL.path(percentEncoded: false) == path || $0.keptPath == path }) {
            return bringForward(old.id, keep: keep)
        }
        guard let mark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let item = newItem(name: url.lastPathComponent, bookmark: mark)
        if insert(item), keep { self.keep(item.id) }
    }

    func add(text: String, keep: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let old = items.first(where: { $0.text == t }) { return bringForward(old.id, keep: keep) }
        let first = t.components(separatedBy: .newlines).first ?? t
        let item = newItem(name: String(first.prefix(40)), text: t)
        if insert(item), keep { self.keep(item.id) }
    }

    private func bringForward(_ id: UUID, keep: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.insert(items.remove(at: i), at: 0)
        save()
        if keep { self.keep(id) }
    }

    private func newItem(name: String, bookmark: Data? = nil, text: String? = nil) -> FridgeItem {
        FridgeItem(name: name, bookmark: bookmark, text: text, tilt: .random(in: -5...5), magnet: .random(in: 0..<Self.magnets.count), addedAt: .now)
    }

    @discardableResult private func insert(_ item: FridgeItem) -> Bool {
        guard let r = Self.adding(item, to: items) else { flash { self.full = true } clear: { self.full = false }; return false }
        items = r.items
        if let (slid, at) = r.slid { flash { self.undo = (item.id, slid, at) } clear: { self.undo = nil } }
        save(); refresh()
        return true
    }

    /// Shows a notice for a few seconds; a newer one replaces it.
    private func flash(_ show: () -> Void, clear: @escaping () -> Void) {
        undo = nil; full = false; cleared = nil; show(); notice += 1
        let n = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.notice == n { clear() } }
    }

    /// Takes back the drop that slid a magnet off.
    func undoSlide() {
        guard let u = undo else { return }
        items.removeAll { $0.id == u.added }
        items.insert(u.slid, at: min(u.at, items.count))
        undo = nil; save(); refresh()
    }

    /// Files, images, links and text from any app. `keep`: dropped on the Keep bar.
    func drop(_ providers: [NSItemProvider], keep: Bool) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { self.add(file: url, keep: keep) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data { DispatchQueue.main.async { self.add(image: data, keep: keep) } }
                }
            } else if p.canLoadObject(ofClass: URL.self) { // a web link: keep it as a note
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { self.add(text: url.absoluteString, keep: keep) } }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    if let s = s as? String { DispatchQueue.main.async { self.add(text: s, keep: keep) } }
                }
            }
        }
    }

    /// An image with no file behind it (from a browser, or copied): saved as a PNG, then linked like any file.
    func add(image data: Data, keep: Bool = false) {
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return }
        let url = Self.unique(Self.dropsDir.appending(path: "Image \(Int(Date.now.timeIntervalSince1970)).png"))
        try? FileManager.default.createDirectory(at: Self.dropsDir, withIntermediateDirectories: true)
        guard (try? png.write(to: url)) != nil else { return }
        add(file: url, keep: keep)
    }

    /// ⌘V: copied files first, then an image, then text (it becomes a note).
    func paste(from pb: NSPasteboard = .general) {
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            files.reversed().forEach { add(file: $0) } // first copied ends up first
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            add(image: data)
        } else if let text = pb.string(forType: .string) {
            add(text: text)
        }
    }

    static func canPaste(_ pb: NSPasteboard = .general) -> Bool {
        pb.availableType(from: [.fileURL, .png, .tiff, .string]) != nil
    }

    // MARK: Keep, remove

    /// Copies the file (or the note) to iCloud Drive › Notch › Fridge. Never moves or changes the original.
    func keep(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.kept, let source = urls[id] else { return }
        let name = item.text == nil ? item.name : Self.safe(item.name) + ".txt"
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = Self.keptDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = Self.unique(dir.appending(path: name))
            guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return }
            DispatchQueue.main.async {
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].keptPath = dest.path(percentEncoded: false)
                self.save(); self.refresh()
            }
        }
    }

    /// Takes the magnet off. The file (and any kept copy) stays where it is.
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if undo?.added == id { undo = nil }
        save(); refresh()
    }

    /// Takes every magnet off, kept ones too. Files and kept copies stay where they are; Undo puts the magnets back.
    func clear() {
        guard !items.isEmpty else { return }
        let all = items
        items = []; save(); refresh()
        flash { self.cleared = all } clear: { self.cleared = nil }
    }

    func undoClear() {
        guard let c = cleared else { return }
        items = Array((c + items.filter { n in !c.contains { $0.id == n.id } }).prefix(Self.limit))
        cleared = nil; save(); refresh()
    }

    // MARK: Files

    /// Finds each original again (it may have moved), falls back to the kept copy, and loads previews.
    func refresh() {
        var urls: [UUID: URL] = [:], info: [UUID: String] = [:]
        for (i, item) in items.enumerated() {
            if let text = item.text {
                let tmp = FileManager.default.temporaryDirectory.appending(path: "Notcho Fridge/\(Self.safe(item.name)).txt")
                try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: tmp, atomically: true, encoding: .utf8)
                urls[item.id] = tmp; info[item.id] = "Note"
                continue
            }
            var stale = false
            var url = item.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            if let u = url, !FileManager.default.fileExists(atPath: u.path(percentEncoded: false)) { url = nil } // in the Trash or gone
            if let u = url, stale { items[i].bookmark = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
            if url == nil, let k = item.keptPath, FileManager.default.fileExists(atPath: k) { url = URL(fileURLWithPath: k) }
            guard let u = url else { info[item.id] = "Missing"; continue }
            urls[item.id] = u
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            info[item.id] = [u.pathExtension.uppercased(), size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if thumbs[item.id] == nil, UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true {
                let id = item.id
                let request = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 124, height: 96), scale: 2, representationTypes: .thumbnail)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    if let image = rep?.nsImage { DispatchQueue.main.async { self.thumbs[id] = image } }
                }
            }
        }
        self.urls = urls; self.info = info
    }

    func isImage(_ item: FridgeItem) -> Bool { thumbs[item.id] != nil }

    /// What a dragged-out magnet carries: the file, or the note's text.
    func provider(_ item: FridgeItem) -> NSItemProvider {
        if let text = item.text { return NSItemProvider(object: text as NSString) }
        return urls[item.id].flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// "brief.pdf" → "brief 2.pdf" when the name is taken.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2... {
            let next = dir.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: next.path(percentEncoded: false)) { return next }
        }
        return url
    }
}

// MARK: - The card

/// Frosted glass doors in Light and Pastel, brushed steel in Dark. Magnets only; there is no inside.
struct FridgeCard: View {
    var fridge = Fridge.shared
    @Environment(\.colorScheme) private var scheme
    @State private var targeted = false     // something is being dragged over the card
    @State private var barTargeted = false  // …over the Keep bar at the bottom
    @FocusState private var focused: Bool
    @State private var preview: URL?
    @State private var showAll = false
    static let ink = Color(nsColor: Tone.hex(0x1D1D1F))   // the doors are light in every look
    static let soft = Color(nsColor: Tone.hex(0x3A3A3C))

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let (points, scale) = Fridge.spots(w: w, h: h)
            let shown = Array(fridge.items.prefix(points.count))
            ZStack(alignment: .topLeading) {
                doors(w, h)
                Card(color: .clear) { header(w); Spacer(minLength: 0) }
                if fridge.items.count > shown.count { more(fridge.items.count - shown.count).position(x: w * 3 / 4, y: h - 24) }
                if fridge.items.isEmpty { empty(w, h) }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    MagnetView(item: item, fridge: fridge, preview: $preview).scaleEffect(scale).position(points[i])
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if targeted || barTargeted { keepBar(w) } else { notice(w) }
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onTapGesture { focused = true } // then ⌘V pastes; magnets keep their own clicks
            .contextMenu {
                Button { fridge.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }.disabled(!Fridge.canPaste())
                Button { fridge.clear() } label: { Label("Clear Fridge", systemImage: "xmark.circle") }.disabled(fridge.items.isEmpty)
            }
            .quickLookPreview($preview)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            // One drop target for the whole card; where it lands decides Keep, so the bar can't flicker away under the pointer.
            .onDrop(of: Fridge.dropTypes, delegate: FridgeDrop(fridge: fridge, keepFrom: h - 54, targeted: $targeted, overBar: $barTargeted))
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onPasteCommand(of: Fridge.dropTypes) { _ in fridge.paste() }
        .onAppear { fridge.refresh() }
    }

    func doors(_ w: CGFloat, _ h: CGFloat) -> some View {
        let name = scheme == .dark ? "fridge-steel" : "fridge-glass"
        return Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else { // a quick test build has no bundled photos
                LinearGradient(colors: [Color(nsColor: Tone.hex(0xE9EBEE)), Color(nsColor: Tone.hex(0xCDD1D6))], startPoint: .top, endPoint: .bottom)
                    .overlay { Rectangle().fill(.black.opacity(0.12)).frame(width: 1) }
            }
        }
        .frame(width: w, height: h, alignment: .top).clipped()
    }

    /// Under 200 wide the title sits on a frosted strip, so the seam doesn't cut "Fridge" in half.
    func header(_ w: CGFloat) -> some View {
        let narrow = w < 200, kept = fridge.items.filter(\.kept).count
        return HStack(spacing: 6) {
            CardHeader(icon: "refrigerator", title: "Fridge", tint: Self.ink)
            Spacer(minLength: 4)
            if !narrow && !fridge.items.isEmpty {
                HStack(spacing: 4) {
                    if kept > 0 { PinBadge().scaleEffect(0.8); Text("\(kept) kept ·") }
                    Text("\(fridge.items.count) of \(Fridge.limit)")
                }
                .font(.callout).foregroundStyle(Self.soft).lineLimit(1)
            }
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, narrow ? 8 : 0).padding(.vertical, narrow ? 5 : 0)
        .background(narrow ? Color.white.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, narrow ? -8 : 0)
    }

    func empty(_ w: CGFloat, _ h: CGFloat) -> some View {
        VStack(spacing: 3) {
            if w >= 200 { Image(systemName: "tray.and.arrow.down").font(.title3) }
            Text("Drop files here").font(.callout.weight(.semibold))
            if w >= 200 { Text("Or click here and paste (⌘V). Up to \(Fridge.limit).").font(.caption).foregroundStyle(Self.soft) }
        }
        .foregroundStyle(Self.ink).multilineTextAlignment(.center)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: w, height: h).offset(y: w < 200 ? 18 : 0).allowsHitTesting(false) // narrow: clear of the title strip
    }

    /// "+N more" sits on the right door; it lists everything.
    func more(_ n: Int) -> some View {
        Button { showAll = true } label: {
            Text("+\(n) more").font(.caption.weight(.semibold)).foregroundStyle(Self.ink)
                .padding(.horizontal, 10).padding(.vertical, 4).background(.white.opacity(0.75), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAll, arrowEdge: .bottom) { allItems }
    }

    var allItems: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(fridge.items) { item in
                    Button { preview = fridge.urls[item.id]; showAll = false } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.kept ? "pin.fill" : item.text != nil ? "note.text" : "doc").frame(width: 16)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(fridge.info[item.id] ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { FridgeMenu(item: item, fridge: fridge, preview: $preview) }
                }
            }
            .padding(6)
        }
        .frame(width: 260).frame(maxHeight: 340)
    }

    /// While dragging: drop on this bar to keep a copy straight away.
    func keepBar(_ w: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: barTargeted ? "arrow.down.to.line.circle.fill" : "tray.and.arrow.down").font(.callout.weight(.semibold))
            Text(w < 200 ? "Drop to keep" : "Drop to keep · saves to iCloud Drive › Notch").font(.callout.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(barTargeted ? .white : Self.ink)
        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 34)
        .background(barTargeted ? AnyShapeStyle(Color(nsColor: Tone.hex(0x0A64D8))) : AnyShapeStyle(Color.white.opacity(0.8)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(barTargeted ? .white.opacity(0.6) : Color(nsColor: Tone.hex(0x0A64D8)).opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        .padding(10)
    }

    /// "invoice.pdf slid off · Undo", or why a drop was refused.
    @ViewBuilder func notice(_ w: CGFloat) -> some View {
        if let u = fridge.undo {
            HStack(spacing: 8) {
                Text(w < 200 ? "Slid off" : "\(u.slid.name) slid off").lineLimit(1).truncationMode(.middle)
                Button("Undo") { fridge.undoSlide() }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Color(nsColor: Tone.hex(0x0A64D8)))
            }
            .modifier(Toast())
        } else if fridge.cleared != nil {
            HStack(spacing: 8) {
                Text("Fridge cleared").lineLimit(1)
                Button("Undo") { fridge.undoClear() }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Color(nsColor: Tone.hex(0x0A64D8)))
            }
            .modifier(Toast())
        } else if fridge.full {
            Text(w < 200 ? "Fridge is full" : "Fridge is full. Remove one first.").lineLimit(1).modifier(Toast())
        }
    }

    struct Toast: ViewModifier {
        func body(content: Content) -> some View {
            content.font(.callout).foregroundStyle(FridgeCard.ink)
                .padding(.horizontal, 12).frame(height: 30)
                .background(.white.opacity(0.92), in: Capsule()).shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                .padding(.bottom, 12).frame(maxWidth: .infinity)
        }
    }
}

/// Dropping onto the card. Anything dropped on the bottom strip (the Keep bar) is kept straight away.
struct FridgeDrop: DropDelegate {
    let fridge: Fridge, keepFrom: CGFloat
    @Binding var targeted: Bool
    @Binding var overBar: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Fridge.dropTypes) }
    func dropEntered(info: DropInfo) { targeted = true; overBar = info.location.y >= keepFrom }
    func dropUpdated(info: DropInfo) -> DropProposal? { overBar = info.location.y >= keepFrom; return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { targeted = false; overBar = false }
    func performDrop(info: DropInfo) -> Bool {
        let keep = info.location.y >= keepFrom
        targeted = false; overBar = false
        fridge.drop(info.itemProviders(for: Fridge.dropTypes), keep: keep)
        return true
    }
}

/// One item on the door: a polaroid for images, a sheet of paper for files, a sticky note for text.
struct MagnetView: View {
    let item: FridgeItem
    let fridge: Fridge
    @Binding var preview: URL?

    var body: some View {
        let url = fridge.urls[item.id]
        face(url)
            .rotationEffect(.degrees(item.tilt))
            .overlay(alignment: .top) { Magnet(color: Fridge.magnets[item.magnet % Fridge.magnets.count]).offset(y: -5) }
            .overlay(alignment: .topTrailing) { if item.kept { PinBadge().offset(x: 6, y: -6) } }
            .opacity(url == nil ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
            .onTapGesture { preview = url }
            .onDrag { fridge.provider(item) }
            .contextMenu { FridgeMenu(item: item, fridge: fridge, preview: $preview) }
            .help(item.name)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(item.name), \(fridge.info[item.id] ?? "")")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder func face(_ url: URL?) -> some View {
        let ink = FridgeCard.ink, soft = FridgeCard.soft
        if let text = item.text {
            Text(text).font(.system(size: 9)).foregroundStyle(ink).lineLimit(6).multilineTextAlignment(.leading)
                .padding(6).frame(width: 66, height: 70, alignment: .topLeading)
                .background(Color(nsColor: Tone.hex(0xFFF3A6))).shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else if let thumb = fridge.thumbs[item.id], url != nil {
            VStack(spacing: 3) {
                Image(nsImage: thumb).resizable().scaledToFill().frame(width: 62, height: 48).clipped()
                Text(item.name).font(.system(size: 9)).foregroundStyle(soft).lineLimit(1).truncationMode(.middle).frame(width: 62)
            }
            .padding(4).padding(.bottom, 1).background(.white).shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else {
            VStack(spacing: 3) {
                if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))).resizable().frame(width: 28, height: 28) }
                else { Image(systemName: "questionmark.folder").font(.system(size: 20)).foregroundStyle(soft).frame(height: 28) }
                Text(item.name).font(.system(size: 9, weight: .medium)).foregroundStyle(ink).lineLimit(1).truncationMode(.middle)
                Text(fridge.info[item.id] ?? "").font(.system(size: 8)).foregroundStyle(soft).lineLimit(1)
            }
            .padding(.horizontal, 4).frame(width: 66, height: 70).background(.white).shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
    }
}

/// Right-click a magnet. A missing file can only be removed.
struct FridgeMenu: View {
    let item: FridgeItem
    let fridge: Fridge
    @Binding var preview: URL?

    var body: some View {
        if let url = fridge.urls[item.id] {
            Button { preview = url } label: { Label("Quick Look", systemImage: "eye") }
            Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Divider()
            if item.kept { Button {} label: { Label("Kept in iCloud Drive › Notch › Fridge", systemImage: "pin.fill") }.disabled(true) }
            else { Button { fridge.keep(item.id) } label: { Label("Keep in Notcho", systemImage: "pin") } }
            Divider()
            if item.text == nil {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
        Button { fridge.remove(item.id) } label: { Label("Remove from Fridge", systemImage: "xmark") }
    }
}

struct Magnet: View {
    let color: Int
    var body: some View {
        Circle().fill(Color(nsColor: Tone.hex(color))).frame(width: 14, height: 14).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            .overlay(Circle().fill(.white.opacity(0.4)).frame(width: 4, height: 4).offset(x: -2, y: -2))
    }
}

struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).rotationEffect(.degrees(45))
            .frame(width: 17, height: 17).background(Color(nsColor: Tone.hex(0x0A64D8)), in: Circle()).overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}
