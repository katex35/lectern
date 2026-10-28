import AppKit
import AVFoundation
import ImageIO
import LecternCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let ref: SessionRef
    @State private var tab: Tab = .notes
    @State private var player = SessionPlayer()
    @State private var question = ""
    @FocusState private var askFocused: Bool
    @Namespace private var tabs

    enum Tab: CaseIterable { case notes, transcript, questions, chat }

    var body: some View {
        if let session = model.session(ref) {
            let thread = model.chat.thread(of: session)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header(session)
                            PlayerBar(player: player)
                            tabBar(session)
                            content(session)
                                .id(tab)
                                .transition(.opacity.combined(with: .offset(y: 6)))
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                    }
                    // the newest answer stays in view while it comes in
                    .onChange(of: (thread.streaming?.count ?? 0) + thread.entries.count * 100_000) {
                        if tab == .chat { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                // text fades out above the field instead of being cut
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                        .allowsHitTesting(false)
                }
                Composer(draft: $question, focused: $askFocused, placeholder: L("session.ask"), showsTools: false) {
                    model.chat.ask(question, in: session)
                    question = ""
                    tab = .chat
                }
                .disabled(model.chat.isAnswering(session))
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .frame(maxWidth: 760)
            }
            .task(id: ref) {
                model.chat.load(session)
                // arriving from a search result: its tab, and in a transcript its moment
                let jump = model.jump?.session == ref ? model.jump : nil
                if let jump {
                    model.jump = nil
                    switch jump.source {
                    case .notes: tab = .notes
                    case .transcript: tab = .transcript
                    case .chat: tab = .chat
                    }
                }
                await player.load(session, folder: model.folder(of: session))
                if let time = jump?.time { player.play(at: time) }
            }
            // photos dropped here belong to this lecture whatever their time
            .dropDestination(for: URL.self) { urls, _ in
                model.addPhotos(urls, to: session)
                return urls.contains(where: BoardPhotos.isPhoto)
            }
            .onDisappear { player.stop() }
        } else {
            Text(L("session.missing"))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ session: Session) -> some View {
        HStack(spacing: 12) {
            CoverView(course: model.course(session.courseID), session: session, width: 40, height: 40, radius: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(SessionText.title(session, model: model))
                    .font(.system(size: 19, weight: .semibold))
                    .kerning(-0.4)
                    .lineLimit(2)
                Text(SessionText.meta(session, model: model))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            ProcessingChip(session: session)
            IconButton(systemName: "photo.badge.plus", label: L("session.addPhotos")) { choosePhotos(for: session) }
        }
    }

    private func choosePhotos(for session: Session) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = BoardPhotos.types
        guard panel.runModal() == .OK else { return }
        model.addPhotos(panel.urls, to: session)
    }

    /// The conversation tab appears once there is something in it.
    private func tabBar(_ session: Session) -> some View {
        let thread = model.chat.thread(of: session)
        let shown = Tab.allCases.filter { $0 != .chat || !thread.entries.isEmpty || thread.streaming != nil }
        return HStack(spacing: 0) {
            ForEach(shown, id: \.self) { item in
                Button {
                    withAnimation(Theme.ease) { tab = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tab == item ? Theme.ink : Theme.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: tabs)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0xF4F4F4)))
    }

    private func label(_ tab: Tab) -> String {
        switch tab {
        case .notes: return L("session.tab.notes")
        case .transcript: return L("session.tab.transcript")
        case .questions: return L("session.tab.questions")
        case .chat: return L("session.tab.chat")
        }
    }

    @ViewBuilder
    private func content(_ session: Session) -> some View {
        switch tab {
        case .notes:
            let folder = model.folder(of: session)
            let notes = model.text("notes.md", in: session)
            let notesBlocks = notes.map { NoteDocument.parse($0, dropsTitle: true) } ?? []
            VStack(alignment: .leading, spacing: 18) {
                // photos the notes already show in their place are not repeated here
                BoardPhotos(session: session, folder: folder, player: player, shown: MarkdownText.photos(in: notesBlocks))
                if notes != nil {
                    MarkdownText(blocks: notesBlocks, folder: folder)
                } else {
                    MarkersList(session: session, player: player)
                    EmptyLine(text: L("session.notesPending"))
                }
            }
        case .transcript:
            if let transcript = model.text("transcript.txt", in: session) {
                Text(transcript)
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .textSelection(.enabled)
            } else {
                EmptyLine(text: L("session.transcriptPending"))
            }
        case .questions:
            if let questions = model.text("questions.md", in: session) {
                MarkdownText(source: questions)
            } else {
                EmptyLine(text: L("session.questionsPending"))
            }
        case .chat:
            ChatView(session: session)
        }
    }
}

/// Where the transcript and notes are, in one small chip at the header's end; it only shows when
/// something is happening or can be done.
private struct ProcessingChip: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let processing = model.processing
        Group {
            switch processing.state(of: session) {
            case .running(let progress)?:
                chip {
                    ProgressView().controlSize(.mini)
                    Text(label(progress)).monospacedDigit().contentTransition(.numericText())
                }
            case .needsGemini?:
                SettingsLink { chip { Text(L("process.needsGemini")) } }.buttonStyle(.plain)
            case .needsWriter?:
                SettingsLink { chip { Text(L("process.needsWriter")) } }.buttonStyle(.plain)
            case .failed(let message)?:
                Button { processing.process(session) } label: {
                    chip {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        Text(L("process.failed"))
                    }
                }
                .buttonStyle(.plain)
                .help(message)
            case nil:
                if processing.hasWork(session, in: model) {
                    Button { processing.process(session) } label: {
                        chip { Text(L("process.start")) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .transition(.opacity)
    }

    private func label(_ progress: ProcessingProgress) -> String {
        switch progress {
        case .preparing: return L("process.preparing")
        case .transcribing(let done, let total): return L("process.transcribing", done, total)
        case .writingNotes: return L("process.notes")
        case .writingQuestions: return L("process.questions")
        case .findingDates: return L("process.dates")
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color(hex: 0xF4F4F4)))
            .contentShape(Capsule())
    }
}

private struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.tertiary)
            .padding(.vertical, 8)
    }
}

/// Notes typed during the lecture, each a jump into the recording.
private struct MarkersList: View {
    let session: Session
    let player: SessionPlayer

    var body: some View {
        if !session.markers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.markers) { marker in
                    let time = player.position(of: marker)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // a note on a recording that cannot be played keeps its time but no jump
                        TimeChip(time: time ?? marker.time) { if let time { player.play(at: time) } }
                            .disabled(time == nil)
                        Text(marker.text).font(.system(size: 14.5))
                    }
                }
            }
        }
    }
}

struct TimeChip: View {
    let time: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 7))
                Text(time.clock).font(.system(size: 11.5).monospacedDigit())
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .overlay(Capsule().strokeBorder(Color(hex: 0xE6E6E6)))
            .contentShape(Capsule())
        }
        .buttonStyle(RowButtonStyle(radius: 11))
        .accessibilityLabel(L("session.playFrom", time.clock))
    }
}

/// Board photos in the order they were taken; each one with a time jumps the player to its moment.
struct BoardPhotos: View {
    /// What can be added and is shown: the formats phones and screenshots produce.
    static let types: [UTType] = [.jpeg, .png, .heic]

    static func isPhoto(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension).map { type in types.contains { type.conforms(to: $0) } } ?? false
    }

    let session: Session
    let folder: URL
    let player: SessionPlayer
    var shown: Set<String> = []

    var body: some View {
        let board = folder.appendingPathComponent("board", isDirectory: true)
        let placed = Dictionary(session.photos.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: board.path)) ?? [])
            .filter { Self.isPhoto(URL(fileURLWithPath: $0)) && !shown.contains($0) }
            .map { (file: $0, time: placed[$0].flatMap(player.position(of:))) }
            .sorted { ($0.time ?? .infinity, $0.file) < ($1.time ?? .infinity, $1.file) }
        if !files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(files, id: \.file) { item in
                        Thumbnail(url: board.appendingPathComponent(item.file), width: 168, height: 112)
                            .overlay(alignment: .bottomLeading) {
                                if let time = item.time {
                                    TimeChip(time: time) { player.play(at: time) }
                                        .background(Capsule().fill(.white.opacity(0.92)))
                                        .padding(6)
                                }
                            }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// A photo scaled down once and kept, so large phone pictures do not slow the page. With a width it
/// fills that tile; without one it keeps its own shape, at most `height` tall, on the left.
struct Thumbnail: View {
    let url: URL
    var width: CGFloat?
    var height: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let width {
                ZStack {
                    Theme.card
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
                .frame(width: width, height: height)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
                    .transition(.opacity)
            } else {
                Theme.card.frame(width: height * 4 / 3, height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .task(id: url) {
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { Thumbnails.image(url, pixels: 900) }.value
            withAnimation(Theme.quick) { image = loaded }
        }
    }
}

enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL, pixels: Int) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Generated notes: headings, lists, tables, formulas and the board photos in their place.
struct MarkdownText: View {
    let blocks: [NoteBlock]
    /// The session folder that photo paths are relative to.
    var folder: URL?
    /// Body text size.
    var size: CGFloat = 15
    /// Light text on a dark card.
    var inverted = false

    init(source: String, dropsTitle: Bool = false, folder: URL? = nil, size: CGFloat = 15, inverted: Bool = false) {
        blocks = NoteDocument.parse(source, dropsTitle: dropsTitle)
        self.folder = folder
        self.size = size
        self.inverted = inverted
    }

    init(blocks: [NoteBlock], folder: URL?) {
        self.blocks = blocks
        self.folder = folder
    }

    /// File names of the board photos placed in these blocks.
    static func photos(in blocks: [NoteBlock]) -> Set<String> {
        Set(blocks.compactMap { block in
            if case .image(let path, _) = block { return URL(fileURLWithPath: path).lastPathComponent }
            return nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(.system(size: level <= 1 ? size + 4 : level == 2 ? size + 1.5 : size, weight: .semibold))
                        .kerning(level <= 2 ? -0.2 : 0)
                        .padding(.top, level <= 2 ? 8 : 2)
                case .paragraph(let text):
                    inline(text).font(.system(size: size))
                case .bullet(let depth, let text):
                    item(marker: depth == 0 ? "•" : "◦", text: text)
                        .padding(.leading, CGFloat(depth) * 18)
                case .numbered(let number, let text):
                    item(marker: "\(number).", text: text)
                case .quote(let text):
                    inline(text)
                        .font(.system(size: size))
                        .foregroundStyle(inverted ? Color.white.opacity(0.72) : Theme.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Capsule().fill(inverted ? Color.white.opacity(0.25) : Theme.field).frame(width: 3) }
                case .table(let header, let rows):
                    NoteTable(header: header, rows: rows, inverted: inverted)
                case .formula(let text):
                    Text(verbatim: text)
                        .font(.system(size: 17, design: .serif).italic())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(inverted ? Color.white.opacity(0.1) : Theme.card))
                case .rule:
                    Rectangle().fill(inverted ? Color.white.opacity(0.18) : Theme.line).frame(height: 1).padding(.vertical, 6)
                case .image(let path, let caption):
                    // only pictures inside the session folder are shown
                    if let folder, !path.contains(".."), !path.hasPrefix("/") {
                        let url = folder.appendingPathComponent(path)
                        VStack(alignment: .leading, spacing: 4) {
                            Thumbnail(url: url, height: 240)
                                .onTapGesture { NSWorkspace.shared.open(url) }
                            if !caption.isEmpty {
                                Text(caption).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .lineSpacing(4)
        .textSelection(.enabled)
    }

    private func item(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker)
                .foregroundStyle(inverted ? Color.white.opacity(0.55) : Theme.tertiary)
                .monospacedDigit()
                .frame(minWidth: 12, alignment: .trailing)
            inline(text)
        }
        .font(.system(size: size))
    }
}

/// Inline Markdown such as bold and code, keeping line breaks.
private func inline(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
    return Text(verbatim: text)
}

private struct NoteTable: View {
    let header: [String]
    let rows: [[String]]
    var inverted = false

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { cells(header, columns: columns, bold: true) }
                .background(inverted ? Color.white.opacity(0.1) : Theme.card)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow { cells(row, columns: columns, bold: false) }
            }
        }
        .font(.system(size: 14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(inverted ? Color.white.opacity(0.18) : Theme.line))
    }

    @ViewBuilder
    private func cells(_ values: [String], columns: Int, bold: Bool) -> some View {
        ForEach(0..<columns, id: \.self) { index in
            inline(index < values.count ? values[index] : "")
                .fontWeight(bold ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Plays a session's recordings back to back as one timeline, with their loudness outline for the scrubber.
@MainActor @Observable
final class SessionPlayer {
    private(set) var envelope: [CGFloat] = []
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private var player: AVPlayer?
    /// Where each recording starts on the session timeline.
    private var offsets: [String: TimeInterval] = [:]
    private var loading: UUID?
    private var endObserver: NSObjectProtocol?

    var currentTime: TimeInterval {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    func load(_ session: Session, folder: URL) async {
        stop()
        let token = UUID()
        loading = token
        player = nil
        envelope = []
        duration = 0
        offsets = [:]
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        var cursor = CMTime.zero
        var parts: [Part] = []
        var offsets: [String: TimeInterval] = [:]
        for recording in session.orderedRecordings where !recording.inProgress {
            let url = folder.appendingPathComponent(recording.file)
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration), length.seconds > 0,
                  (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: cursor)) != nil
            else { continue }
            offsets[recording.file] = cursor.seconds
            parts.append(Part(url: url, length: length.seconds))
            cursor = cursor + length
        }
        // a different session may have been opened meanwhile
        guard loading == token, !parts.isEmpty else { return }
        self.offsets = offsets
        duration = cursor.seconds
        let item = AVPlayerItem(asset: composition)
        player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }

        let outline = await Self.outline(of: parts, total: duration)
        guard loading == token else { return }
        withAnimation(Theme.ease) { envelope = outline }
    }

    private struct Part: Sendable {
        let url: URL
        let length: TimeInterval
    }

    /// 120 bars over the whole timeline; each recording gets bars in proportion to its length.
    private nonisolated static func outline(of parts: [Part], total: TimeInterval) async -> [CGFloat] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.lectern/Envelopes", isDirectory: true)
        // user-initiated: at utility priority a long lecture waited behind other work for many seconds
        return await Task.detached(priority: .userInitiated) {
            parts.flatMap { part in
                let bars = max(1, Int((120 * part.length / total).rounded()))
                let values = Envelope.cached(part.url, buckets: bars, in: cache)
                // a part that cannot be read keeps its width, so later parts stay under their audio
                return (values.isEmpty ? Array(repeating: 0, count: bars) : values).map { CGFloat($0) }
            }
        }.value
    }

    /// Where a note typed during the lecture sits on the session timeline.
    /// nil while loading, or when its recording could not be put on the timeline.
    func position(of marker: Marker) -> TimeInterval? {
        offsets[marker.recording].map { $0 + marker.time }
    }

    /// nil for a photo not placed on the timeline, or while loading.
    func position(of photo: BoardPhoto) -> TimeInterval? {
        guard let recording = photo.recording, let time = photo.time else { return nil }
        return offsets[recording].map { $0 + time }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.5 { player.seek(to: .zero) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to fraction: Double) {
        play(at: duration * min(1, max(0, fraction)), start: false)
    }

    func play(at time: TimeInterval, start: Bool = true) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if start {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
    }
}

private struct PlayerBar: View {
    let player: SessionPlayer

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.ink))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? L("player.pause") : L("player.play"))
            .keyboardShortcut(.space, modifiers: [])

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
                GeometryReader { proxy in
                    HStack(alignment: .center, spacing: 2) {
                        let values = player.envelope.isEmpty ? Array(repeating: CGFloat(0), count: 120) : player.envelope
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            Capsule()
                                .fill(Double(index) / Double(values.count) <= fraction ? Theme.ink : Color(hex: 0xCFCFCF))
                                .frame(height: 3 + 15 * value)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        player.seek(to: Double(value.location.x / max(1, proxy.size.width)))
                    })
                }
                .frame(height: 20)
                .animation(Theme.ease, value: player.envelope.count)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(verbatim: player.duration > 0 ? "\(player.currentTime.clock) / \(player.duration.clock)" : "00:00")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .padding(.trailing, 10)
            }
        }
        .padding(.leading, 5)
        .frame(height: 38)
        .background(Capsule().fill(Color(hex: 0xF4F4F4)))
    }
}
