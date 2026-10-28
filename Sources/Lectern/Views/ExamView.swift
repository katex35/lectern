import LecternCore
import SwiftUI

/// Exam practice: the questions of the chosen weeks as cards to turn over, missed ones first.
struct ExamView: View {
    @Environment(AppModel.self) private var model
    /// The course asked for; nil picks the one with the nearest exam.
    let courseID: String?
    @State private var weeks: Set<String> = []
    @State private var deck: [Deck.Item] = []
    @State private var position = 0
    @State private var results: [Bool] = []
    /// Each card's first answer this round: asked-again cards come back until known, so only this says what was known.
    @State private var firstTries: [String: Bool] = [:]
    @State private var flipped = false
    @State private var appeared = false
    @FocusState private var focused: Bool

    var body: some View {
        let course = self.course
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let course {
                    header(course)
                        .enter(appeared, delay: 0)
                    if practiced.count > 1 { courseChips(course) }
                    weekChips(course)
                        .enter(appeared, delay: 0.04)
                    if deck.isEmpty {
                        Text(L("exam.noCards"))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiary)
                    } else {
                        progress
                        if position < deck.count {
                            card(deck[position])
                                .id(deck[position].id)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                                        removal: .opacity.combined(with: .offset(x: -24))))
                            answers
                        } else {
                            finished
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                } else {
                    Text(L("exam.title"))
                        .font(.system(size: 24, weight: .semibold))
                        .kerning(-0.5)
                    Text(L("exam.empty"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) { flip(); return .handled }
        .onKeyPress(.rightArrow) { answer(known: true); return .handled }
        .onKeyPress(.leftArrow) { answer(known: false); return .handled }
        .onAppear {
            appeared = true
            focused = true
        }
        .task(id: course?.id) { resetWeeks() }
        .onChange(of: weeks) { deal() }
    }

    // MARK: course and weeks

    /// Courses that have questions to practise, with their lectures that do.
    private var practiced: [(course: Course, sessions: [Session])] {
        model.courses.compactMap { course in
            let sessions = model.sessions.filter { $0.courseID == course.id && model.text("questions.md", in: $0) != nil }
            return sessions.isEmpty ? nil : (course, sessions)
        }
    }

    private var course: Course? {
        let candidates = practiced.map(\.course)
        if let courseID, let asked = candidates.first(where: { $0.id == courseID }) { return asked }
        // the nearest exam, else the course practised most recently
        let exams = CourseDate.upcoming(in: candidates, from: Date(), days: 120).filter { $0.date.kind == .exam }
        return exams.first?.course ?? practiced.max { ($0.sessions.first?.date ?? .distantPast) < ($1.sessions.first?.date ?? .distantPast) }?.course
    }

    private var exam: CourseDate? {
        guard let course else { return nil }
        return CourseDate.upcoming(in: [course], from: Date(), days: 120).first { $0.date.kind == .exam }?.date
    }

    private func lectures(of course: Course) -> [Session] {
        (practiced.first { $0.course.id == course.id }?.sessions ?? []).sorted { $0.date < $1.date }
    }

    private func weekLabel(_ session: Session) -> String {
        session.week.map { L("session.week", $0) } ?? session.date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func resetWeeks() {
        guard let course else { return }
        let all = Set(lectures(of: course).map(\.id))
        if weeks == all { deal() } else { weeks = all }
    }

    /// Cards of the chosen weeks, in the order the log gives.
    private func deal() {
        guard let course else { return }
        var items: [Deck.Item] = []
        for session in lectures(of: course) where weeks.contains(session.id) {
            guard let text = model.text("questions.md", in: session) else { continue }
            for card in PracticeCards.parse(text, prefix: session.id) {
                items.append(Deck.Item(card: card, session: session, week: weekLabel(session)))
            }
        }
        let ordered = model.library.practiceLog(ofCourse: course.id).order(items.map(\.card))
        let byID = Dictionary(items.map { ($0.card.id, $0) }, uniquingKeysWith: { first, _ in first })
        withAnimation(Theme.ease) {
            deck = ordered.compactMap { byID[$0.id] }
            position = 0
            results = []
            firstTries = [:]
            flipped = false
        }
    }

    private func header(_ course: Course) -> some View {
        HStack(spacing: 12) {
            CoverView(course: course, width: 44, height: 44, radius: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: exam.map { "\(course.shortName) · \($0.title.isEmpty ? L("course.kind.exam") : $0.title)" } ?? course.shortName)
                    .font(.system(size: 22, weight: .semibold))
                    .kerning(-0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(summary)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    /// "Vize 16 gün sonra · 3 hafta · 18 kart · 2 bildin"
    private var summary: String {
        var parts: [String] = []
        if let exam { parts.append(RelativeTime.until(exam.date)) }
        parts.append(plural("exam.weeks", weeks.count))
        parts.append(plural("exam.cards", deck.count))
        if !firstTries.isEmpty { parts.append(L("exam.knew", knownFirstTime)) }
        return parts.joined(separator: " · ")
    }

    private func courseChips(_ current: Course) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(practiced, id: \.course.id) { item in
                FilterChip(label: item.course.shortName, course: item.course, on: item.course.id == current.id) {
                    model.go(to: .exam(item.course.id))
                }
            }
        }
    }

    private func weekChips(_ course: Course) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(lectures(of: course), id: \.ref) { session in
                let on = weeks.contains(session.id)
                FilterChip(label: weekLabel(session), course: nil, on: on) {
                    // at least one week stays chosen
                    if on, weeks.count > 1 { weeks.remove(session.id) } else { weeks.insert(session.id) }
                }
            }
        }
    }

    // MARK: the card

    /// One mark per card: green known, amber asked again, black the one on show. A long deck is one bar.
    @ViewBuilder
    private var progress: some View {
        if deck.count <= 40 {
            HStack(spacing: 4) {
                ForEach(0..<deck.count, id: \.self) { index in
                    Capsule()
                        .fill(index < results.count ? (results[index] ? Color(hex: 0x10B981) : Color(hex: 0xF59E0B))
                              : index == results.count ? Theme.ink : Color(hex: 0xE6E6E6))
                        .frame(height: 4)
                }
            }
            .animation(Theme.ease, value: results.count)
        } else {
            GeometryReader { proxy in
                Capsule().fill(Color(hex: 0xE6E6E6))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.ink)
                            .frame(width: proxy.size.width * CGFloat(position) / CGFloat(max(1, deck.count)))
                    }
            }
            .frame(height: 4)
            .animation(Theme.ease, value: position)
        }
    }

    /// Cards known the first time they came up this round.
    private var knownFirstTime: Int { firstTries.values.filter { $0 }.count }

    private func card(_ item: Deck.Item) -> some View {
        ZStack {
            face(back: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: "\(item.week) · \(L("exam.question"))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                    MarkdownText(source: item.card.question, size: 17)
                    Spacer(minLength: 0)
                    Text(L("exam.flipHint"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .modifier(Turn(angle: flipped ? 180 : 0, back: false))
            face(back: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("exam.answer"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    if item.card.answer.isEmpty {
                        Text(L("exam.noAnswer")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                    } else {
                        MarkdownText(source: item.card.answer, size: 16, inverted: true)
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                    Button { model.open(item.session) } label: {
                        Label(L("exam.openLecture"), systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .modifier(Turn(angle: flipped ? 180 : 0, back: true))
        }
        .animation(.timingCurve(0.22, 0.9, 0.24, 1, duration: 0.5), value: flipped)
        .contentShape(Rectangle())
        .onTapGesture { flip() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(flipped ? L("exam.toQuestion") : L("exam.showAnswer"))
    }

    /// Both faces are one size, so the card keeps its shape as it turns; a long answer scrolls inside.
    private func face<Content: View>(back: Bool, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .frame(height: 330)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(back ? Theme.ink : Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var answers: some View {
        HStack(spacing: 8) {
            Button { answer(known: false) } label: {
                Text(L("exam.again")).frame(maxWidth: .infinity)
            }
            .buttonStyle(WideButtonStyle(primary: false))
            .help(L("exam.againHint"))
            Button { answer(known: true) } label: {
                Text(L("exam.knewIt")).frame(maxWidth: .infinity)
            }
            .buttonStyle(WideButtonStyle(primary: true))
            .help(L("exam.knewHint"))
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("exam.done"))
                .font(.system(size: 19, weight: .semibold))
                .kerning(-0.3)
            Text(L("exam.doneSummary", knownFirstTime, firstTries.count))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                Button(L("exam.restart")) { deal() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
    }

    private func flip() {
        guard position < deck.count else { return }
        flipped.toggle()
    }

    /// Known: on to the next. Not yet: it comes back a few cards later. Either way it is logged for next time.
    private func answer(known: Bool) {
        guard position < deck.count, let course else { return }
        let item = deck[position]
        var log = model.library.practiceLog(ofCourse: course.id)
        log.record(item.card.id, known: known)
        try? model.library.save(log, ofCourse: course.id)
        flipped = false
        withAnimation(Theme.ease) {
            results.append(known)
            if firstTries[item.card.id] == nil { firstTries[item.card.id] = known }
            if !known {
                deck.insert(Deck.Item(card: item.card, session: item.session, week: item.week), at: min(deck.count, position + 4))
            }
            position += 1
        }
    }
}

enum Deck {
    struct Item: Identifiable {
        let card: PracticeCard
        let session: Session
        let week: String
        /// The same card asked again is a new item on screen.
        let id = UUID()
    }
}

/// One face of a card turning over: the face swaps at the halfway point, and the back is drawn turned
/// so it reads the right way once the card has turned.
private struct Turn: ViewModifier, Animatable {
    var angle: Double
    let back: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let showing = back ? angle >= 90 : angle < 90
        content
            .rotation3DEffect(.degrees(back ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            .opacity(showing ? 1 : 0)
            .allowsHitTesting(showing)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

/// The two wide answer buttons under a card.
private struct WideButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(primary ? .white : Theme.ink)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(primary ? Theme.ink : .white))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(primary ? .clear : Theme.field))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
