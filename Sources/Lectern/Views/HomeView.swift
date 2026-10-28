import LecternCore
import SwiftUI

/// What is next: the coming lecture with one big record button, the week, and notes that are ready.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(greeting)
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.7)
                    .enter(appeared, delay: 0)

                NextCard()
                    .enter(appeared, delay: 0.06)

                if !weekDays.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Caption(text: L("home.thisWeek"))
                        HStack(spacing: 8) {
                            ForEach(weekDays) { day in DayTile(day: day) }
                        }
                    }
                    .enter(appeared, delay: 0.12)
                }

                if !ready.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Caption(text: L("home.ready"))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(ready, id: \.id) { session in ReadyCard(session: session) }
                        }
                    }
                    .enter(appeared, delay: 0.18)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onAppear { appeared = true }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let key = hour < 5 ? "home.greeting.night" : hour < 12 ? "home.greeting.morning" : hour < 18 ? "home.greeting.afternoon" : "home.greeting.evening"
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        return L(key, name)
    }

    /// Monday to Friday of this week, each day's first lecture.
    private var weekDays: [WeekDay] {
        let calendar = Calendar.current
        let today = Date()
        let todayISO = model.schedule.isoWeekday(of: today)
        let next = model.nextLecture
        return (1...5).compactMap { weekday in
            let slots = model.courses.flatMap { course in course.slots.filter { $0.weekday == weekday }.map { (course, $0) } }
            guard let (course, slot) = slots.min(by: { $0.1.start < $1.1.start }),
                  let date = calendar.date(byAdding: .day, value: weekday - todayISO, to: today) else { return nil }
            let done = model.sessions.contains { $0.courseID == course.id && calendar.isDate($0.date, inSameDayAs: date) }
            let isNext = next.map { $0.course.id == course.id && calendar.isDate($0.start, inSameDayAs: date) } ?? false
            let name = weekday == todayISO ? L("time.today") : date.formatted(.dateTime.weekday(.abbreviated))
            return WeekDay(id: weekday, name: name, course: course, time: slot.start.description, done: done, next: isNext,
                           session: model.sessions.first { $0.courseID == course.id && calendar.isDate($0.date, inSameDayAs: date) })
        }
    }

    /// The latest sessions that already have notes.
    private var ready: [Session] {
        Array(model.sessions.filter { model.text("notes.md", in: $0) != nil }.prefix(3))
    }
}

struct WeekDay: Identifiable {
    let id: Int
    let name: String
    let course: Course
    let time: String
    let done: Bool
    let next: Bool
    let session: Session?
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.tertiary)
    }
}

private struct NextCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let next = model.nextLecture
        let current = model.currentLecture
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    CoverView(course: current ?? next?.course, width: 56, height: 56, radius: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current?.name ?? next?.course.name ?? L("home.noSchedule"))
                            .font(.system(size: 20, weight: .semibold))
                            .kerning(-0.4)
                        Text(subtitle(current: current, next: next))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button { model.record(current ?? next?.course) } label: {
                        Label(L("home.record"), systemImage: "mic.fill")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 46))
                    .keyboardShortcut("r", modifiers: [.command, .option])

                    Button { model.record(nil, meeting: true) } label: {
                        Label(L("home.meeting"), systemImage: "person.2")
                    }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 46))
                }
            }
            Spacer(minLength: 0)
            SoundToNotes()
                .frame(width: 300, height: 102)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
    }

    private func subtitle(current: Course?, next: (course: Course, start: Date)?) -> String {
        if current != nil { return L("home.onNow") }
        guard let next else { return L("home.addSchedule") }
        return "\(RelativeTime.dayAndTime(next.start)) · \(RelativeTime.until(next.start))"
    }
}

private struct DayTile: View {
    @Environment(AppModel.self) private var model
    let day: WeekDay

    var body: some View {
        Button {
            if let session = day.session { model.open(session) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(day.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                    if day.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: 0x10B981))
                    }
                }
                Capsule()
                    .fill(Theme.color(of: day.course, among: model.courses))
                    .frame(height: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text(day.course.shortName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(day.time)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(day.next ? Theme.ink : Theme.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftButtonStyle())
        .disabled(day.session == nil)
    }
}

private struct ReadyCard: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Button { model.open(session) } label: {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { proxy in
                    CoverView(course: model.course(session.courseID), session: session,
                              width: proxy.size.width, height: 132, radius: 12)
                }
                .frame(height: 132)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SessionText.title(session, model: model))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(SessionText.meta(session, model: model))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftButtonStyle())
    }
}

/// Cards rise a little under the pointer.
struct LiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration)
    }

    private struct LiftBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .shadow(color: .black.opacity(hovering ? 0.07 : 0), radius: 14, y: 8)
                .offset(y: hovering ? -2 : 0)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(Theme.quick, value: hovering)
                .animation(Theme.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A microphone whose sound waves flow into a card and become lines of notes.
struct SoundToNotes: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let s = size.width / 440
                // rings around the microphone
                for k in 0..<2 {
                    let phase = (t / 2.4 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                    let r = 34 * s * (1 + 0.9 * phase)
                    context.stroke(Path(ellipseIn: CGRect(x: 62 * s - r, y: 75 * s - r, width: 2 * r, height: 2 * r)),
                                   with: .color(Theme.ink.opacity(0.4 * (1 - phase))), lineWidth: 1.5 * s)
                }
                context.fill(Path(ellipseIn: CGRect(x: 28 * s, y: 41 * s, width: 68 * s, height: 68 * s)), with: .color(Theme.ink))
                var mic = Path(roundedRect: CGRect(x: 54 * s, y: 56 * s, width: 16 * s, height: 26 * s), cornerRadius: 8 * s)
                mic.move(to: CGPoint(x: 46 * s, y: 72 * s))
                mic.addQuadCurve(to: CGPoint(x: 78 * s, y: 72 * s), control: CGPoint(x: 62 * s, y: 96 * s))
                mic.move(to: CGPoint(x: 62 * s, y: 88 * s))
                mic.addLine(to: CGPoint(x: 62 * s, y: 95 * s))
                context.stroke(mic, with: .color(.white), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
                // waves travelling to the card
                let heights: [Double] = [16, 30, 22, 44, 60, 38, 26, 52, 34, 20, 40, 28, 18, 30, 14, 10]
                for (i, h) in heights.enumerated() {
                    let wobble = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 4.8 - Double(i) * 0.55))
                    let height = h * wobble * s
                    let x = (116 + Double(i) * 11) * s
                    context.fill(Path(roundedRect: CGRect(x: x, y: 75 * s - height / 2, width: 5 * s, height: height), cornerRadius: 2.5 * s),
                                 with: .color(Theme.ink.opacity(1 - Double(i) * 0.045)))
                }
                // the card and its lines writing themselves
                let card = CGRect(x: 300 * s, y: 24 * s, width: 120 * s, height: 102 * s)
                context.fill(Path(roundedRect: card.offsetBy(dx: 2 * s, dy: 6 * s), cornerRadius: 16 * s), with: .color(.black.opacity(0.05)))
                context.fill(Path(roundedRect: card, cornerRadius: 16 * s), with: .color(.white))
                context.stroke(Path(roundedRect: card, cornerRadius: 16 * s), with: .color(Theme.field), lineWidth: 1)
                let cycle = (t / 4.2).truncatingRemainder(dividingBy: 1)
                let lines: [(Double, Double)] = [(50, 398), (67, 386), (84, 402), (101, 366)]
                for (i, line) in lines.enumerated() {
                    let start = 0.08 + Double(i) * 0.07
                    let grow = min(1, max(0, (cycle - start) / 0.24)) * (cycle > 0.86 ? max(0, 1 - (cycle - 0.86) / 0.14) : 1)
                    guard grow > 0 else { continue }
                    if i == 2 {
                        context.fill(Path(roundedRect: CGRect(x: 314 * s, y: 78 * s, width: 70 * s * grow, height: 13 * s), cornerRadius: 4 * s),
                                     with: .color(Theme.record.opacity(0.2)))
                    }
                    var path = Path()
                    path.move(to: CGPoint(x: 318 * s, y: line.0 * s))
                    path.addLine(to: CGPoint(x: (318 + (line.1 - 318) * grow) * s, y: line.0 * s))
                    context.stroke(path, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Fades and lifts into place when `visible` turns true.
    func enter(_ visible: Bool, delay: Double) -> some View {
        opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .animation(Theme.ease.delay(delay), value: visible)
    }
}
