import LecternCore
import SwiftUI

/// Search across every lecture's notes, transcript and conversation, in a panel over the window.
struct SearchPanel: View {
    @Environment(AppModel.self) private var model
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    private var query: String { model.searchQuery }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.tertiary)
                    TextField(L("search.prompt"), text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { if let first = hits.first { open(first) } }
                    Text(verbatim: "esc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.field))
                }
                .padding(.horizontal, 16)
                .frame(height: 50)

                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    results
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.14), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onExitCommand { close() }
        .task(id: query) {
            // a short pause, so each key does not read every file
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            hits = LibrarySearch.search(query, in: model.sessions, library: model.library)
        }
    }

    @ViewBuilder
    private var results: some View {
        if hits.isEmpty {
            Text(L("search.none"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else if hits.count <= 6 {
            list
        } else {
            // a few results keep the panel short; many scroll inside it
            ScrollView { list }.frame(height: 420)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.0) { _, group in
                Text(SessionText.title(group[0].session, model: model))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(group) { hit in row(hit) }
            }
        }
        .padding(6)
    }

    /// Hits of one lecture together, in the order they came.
    private var groups: [(String, [SearchHit])] {
        var order: [String] = []
        var byKey: [String: [SearchHit]] = [:]
        for hit in hits {
            let key = "\(hit.session.courseID ?? "")/\(hit.session.id)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(hit)
        }
        return order.map { ($0, byKey[$0] ?? []) }
    }

    private func row(_ hit: SearchHit) -> some View {
        Button { open(hit) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(hit.snippet))
                        .font(.system(size: 13.5))
                        .lineLimit(2)
                    Text(sourceName(hit.source))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 8)
                if let time = hit.time {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 7))
                        Text(time.clock).font(.system(size: 11.5).monospacedDigit())
                    }
                    .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    /// The snippet with every search word in bold.
    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        let folded = LibrarySearch.fold(snippet)
        for word in LibrarySearch.fold(query).split(separator: " ") where word.count >= 2 {
            var from = folded.startIndex
            while let found = folded.range(of: word, range: from..<folded.endIndex) {
                let start = folded.distance(from: folded.startIndex, to: found.lowerBound)
                let length = folded.distance(from: found.lowerBound, to: found.upperBound)
                // folding keeps the letter count, so the same offsets mark the original text
                let chars = text.characters
                if start + length <= chars.count {
                    let lower = chars.index(chars.startIndex, offsetBy: start)
                    let upper = chars.index(lower, offsetBy: length)
                    text[lower..<upper].font = .system(size: 13.5, weight: .semibold)
                }
                from = found.upperBound
            }
        }
        return text
    }

    private func sourceName(_ source: SearchHit.Source) -> String {
        switch source {
        case .notes: return L("session.tab.notes")
        case .transcript: return L("session.tab.transcript")
        case .chat: return L("session.tab.chat")
        }
    }

    private func open(_ hit: SearchHit) {
        model.jump = AppModel.Jump(session: SessionRef(hit.session), source: hit.source, time: hit.time)
        model.open(hit.session)
        close()
    }

    private func close() {
        withAnimation(Theme.quick) { model.searching = false }
    }
}
