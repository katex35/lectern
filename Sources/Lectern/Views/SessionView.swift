import AppKit
import AVFoundation
import LecternCore
import Observation
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let ref: SessionRef
    @State private var tab: Tab = .notes
    @State private var player = SessionPlayer()
    @State private var question = ""
    @State private var askHint = false
    @FocusState private var askFocused: Bool
    @Namespace private var tabs

    enum Tab: CaseIterable { case notes, transcript, questions }

    var body: some View {
        if let session = model.session(ref) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(session)
                        PlayerBar(player: player)
                        tabBar
                        content(session)
                            .id(tab)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: 8) {
                    if askHint {
                        HStack(spacing: 6) {
                            Text(L("session.askNeedsAccount"))
                            SettingsLink { Text(L("session.openSettings")).underline() }
                                .buttonStyle(.plain)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Composer(draft: $question, focused: $askFocused, placeholder: L("session.ask"), showsTools: false) {
                        withAnimation(Theme.ease) { askHint = true }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: 760)
            }
            .task(id: ref) { player.load(session, folder: model.folder(of: session)) }
            .onDisappear { player.stop() }
        } else {
            Text(L("session.missing"))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ session: Session) -> some View {
        HStack(spacing: 14) {
            CoverView(course: model.course(session.courseID), session: session, width: 56, height: 56, radius: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionText.title(session, model: model))
                    .font(.system(size: 24, weight: .semibold))
                    .kerning(-0.6)
                    .lineLimit(2)
                Text(SessionText.meta(session, model: model))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.ease) { tab = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tab == item ? Theme.ink : Theme.secondary)
                        .frame(width: 104, height: 32)
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
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
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xF4F4F4)))
    }

    private func label(_ tab: Tab) -> String {
        switch tab {
        case .notes: return L("session.tab.notes")
        case .transcript: return L("session.tab.transcript")
        case .questions: return L("session.tab.questions")
        }
    }

    @ViewBuilder
    private func content(_ session: Session) -> some View {
        switch tab {
        case .notes:
            VStack(alignment: .leading, spacing: 18) {
                BoardPhotos(folder: model.folder(of: session).appendingPathComponent("board", isDirectory: true))
                if let notes = model.text("notes.md", in: session) {
                    MarkdownText(source: notes, title: SessionText.title(session, model: model))
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
        }
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
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        TimeChip(time: marker.time) { player.play(file: marker.recording, at: marker.time) }
                        Text(marker.text).font(.system(size: 15))
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
                Image(systemName: "play.fill").font(.system(size: 8))
                Text(time.clock).font(.system(size: 12).monospacedDigit())
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .overlay(Capsule().strokeBorder(Color(hex: 0xE6E6E6)))
            .contentShape(Capsule())
        }
        .buttonStyle(RowButtonStyle(radius: 12))
        .accessibilityLabel(L("session.playFrom", time.clock))
    }
}

private struct BoardPhotos: View {
    let folder: URL

    var body: some View {
        let images = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        if !images.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(images, id: \.self) { url in
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 220, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// Generated notes: headings, lists, tables and formulas.
struct MarkdownText: View {
    let blocks: [NoteBlock]

    init(source: String, title: String? = nil) {
        blocks = NoteDocument.parse(source, droppingTitle: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(.system(size: level <= 1 ? 22 : level == 2 ? 18 : 16, weight: .semibold))
                        .kerning(level <= 2 ? -0.3 : 0)
                        .padding(.top, level <= 2 ? 10 : 4)
                case .paragraph(let text):
                    inline(text).font(.system(size: 15))
                case .bullet(let depth, let text):
                    item(marker: depth == 0 ? "•" : "◦", text: text)
                        .padding(.leading, CGFloat(depth) * 18)
                case .numbered(let number, let text):
                    item(marker: "\(number).", text: text)
                case .quote(let text):
                    inline(text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Capsule().fill(Theme.field).frame(width: 3) }
                case .table(let header, let rows):
                    NoteTable(header: header, rows: rows)
                case .formula(let text):
                    Text(verbatim: text)
                        .font(.system(size: 17, design: .serif).italic())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                case .rule:
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 6)
                }
            }
        }
        .lineSpacing(4)
        .textSelection(.enabled)
    }

    private func item(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker)
                .foregroundStyle(Theme.tertiary)
                .monospacedDigit()
                .frame(minWidth: 12, alignment: .trailing)
            inline(text)
        }
        .font(.system(size: 15))
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

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { cells(header, columns: columns, bold: true) }
                .background(Theme.card)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow { cells(row, columns: columns, bold: false) }
            }
        }
        .font(.system(size: 14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
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

/// Plays a session's recordings and keeps their loudness outline for the scrubber.
@MainActor @Observable
final class SessionPlayer {
    private(set) var envelope: [CGFloat] = []
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var files: [URL] = []
    private var folder: URL?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    func load(_ session: Session, folder: URL) {
        stop()
        self.folder = folder
        files = session.orderedRecordings.map { folder.appendingPathComponent($0.file) }
        guard let first = files.first else { return }
        player = try? AVAudioPlayer(contentsOf: first)
        duration = player?.duration ?? 0
        envelope = []
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.lectern/Envelopes", isDirectory: true)
        Task.detached(priority: .userInitiated) { [first] in
            let outline = Envelope.cached(first, buckets: 120, in: cache).map { CGFloat($0) }
            await MainActor.run { [weak self] in
                // a different session may have been opened meanwhile
                guard let self, self.files.first == first else { return }
                withAnimation(Theme.ease) { self.envelope = outline }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, duration * fraction))
    }

    func play(file: String, at time: TimeInterval) {
        guard let folder else { return }
        let url = folder.appendingPathComponent(file)
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
        }
        player?.currentTime = time
        player?.play()
        isPlaying = player?.isPlaying ?? false
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}

private struct PlayerBar: View {
    let player: SessionPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
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
                                .frame(height: 4 + 22 * value)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        player.seek(to: Double(value.location.x / max(1, proxy.size.width)))
                    })
                }
                .frame(height: 28)
                .animation(Theme.ease, value: player.envelope.count)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(player.currentTime.clock)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, 6)
        .frame(height: 48)
        .background(Capsule().fill(Color(hex: 0xF4F4F4)))
    }
}
