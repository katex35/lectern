import LecternCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // room for the window's traffic lights
                Color.clear.frame(width: 62, height: 1)
                LogoMark(size: 20)
                Text(verbatim: "Lectern")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(-0.3)
                Spacer(minLength: 0)
                IconButton(systemName: "magnifyingglass", label: L("menu.search")) {
                    withAnimation(Theme.quick) { model.searching = true }
                }
                IconButton(systemName: "square.and.pencil", label: L("sidebar.new")) { model.goHome() }
            }
            .frame(height: 52)
            .padding(.trailing, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NextLectureCard()
                        .padding(.bottom, 8)

                    NavRow(systemName: "waveform", label: L("archive.title"), badge: model.sessions.isEmpty ? nil : "\(model.sessions.count)",
                           selected: model.screen == .archive(.all) || model.screen == .archive(.meetings)) {
                        model.go(to: .archive(.all))
                    }
                    NavRow(systemName: "calendar", label: L("schedule.title"), badge: nil, selected: model.screen == .schedule) {
                        model.go(to: .schedule)
                    }

                    SectionLabel(text: L("sidebar.courses")) {
                        IconButton(systemName: "plus", label: L("sidebar.addCourse"), size: 20) { model.addCourse() }
                    }
                    ForEach(model.courses) { course in
                        CourseRow(course: course)
                    }

                    let recent = Array(model.sessions.prefix(8))
                    if !recent.isEmpty {
                        SectionLabel(text: L("sidebar.recent"))
                        ForEach(recent, id: \.ref) { session in
                            SessionRow(session: session)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            UserRow()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .frame(width: 248)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

private struct SectionLabel<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

extension SectionLabel where Accessory == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

private struct NextLectureCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let next = model.nextLecture {
            Button { model.record(next.course) } label: {
                HStack(spacing: 8) {
                    CoverView(course: next.course, width: 30, height: 30, radius: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(next.course.shortName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(RelativeTime.dayAndTime(next.start))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.ink))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(L("sidebar.recordNext", next.course.name))
        }
    }
}

private struct NavRow: View {
    let systemName: String
    let label: String
    let badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected))
    }
}

private struct CourseRow: View {
    @Environment(AppModel.self) private var model
    let course: Course

    var body: some View {
        let count = model.sessions.filter { $0.courseID == course.id }.count
        let selected = model.screen == .archive(.course(course.id))
        Button {
            model.go(to: .archive(.course(course.id)))
        } label: {
            HStack(spacing: 8) {
                CoverView(course: course, width: 20, height: 20, radius: 6)
                Text(course.shortName)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .contextMenu {
            Button(L("course.edit")) { model.edit(course) }
            if Covers.maker() != nil {
                Button(L("course.redrawCover")) { Task { await Covers.draw(for: course, model: model, replacing: true) } }
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let selected = model.screen == .session(SessionRef(session))
        Button { model.open(session) } label: {
            HStack(spacing: 8) {
                Text(SessionText.shortTitle(session, model: model))
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if session.totalDuration > 0 {
                    Text(RelativeTime.duration(session.totalDuration))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected))
    }
}

private struct UserRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        HStack(spacing: 8) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.ink))
            Text(name)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle(radius: 7))
            .accessibilityLabel(L("sidebar.settings"))
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
    }
}

/// Titles and dates shown for sessions.
@MainActor
enum SessionText {
    /// The first heading of the notes, else "Week 6" or the meeting title.
    static func title(_ session: Session, model: AppModel) -> String {
        if let notes = model.text("notes.md", in: session), let heading = NoteDocument.title(of: notes) {
            return heading
        }
        if session.kind == .meeting {
            // an untitled meeting is named after its folder, "2026-09-22-1552"; the time tells two on one day apart
            let untitled = session.title.first?.isNumber == true && session.title.contains("-")
            return untitled ? "\(L("session.meeting")) · \(RelativeTime.dayAndTime(session.date))" : session.title
        }
        return session.week.map { L("session.week", $0) } ?? session.title
    }

    static func shortTitle(_ session: Session, model: AppModel) -> String {
        let title = title(session, model: model)
        if session.kind == .meeting || title != session.title { return title }
        return session.week.map { L("session.week", $0) } ?? title
    }

    static func meta(_ session: Session, model: AppModel) -> String {
        var parts: [String] = []
        if let course = model.course(session.courseID) { parts.append(course.shortName) } else { parts.append(L("session.meeting")) }
        parts.append(RelativeTime.day(session.date))
        if session.totalDuration > 0 { parts.append(RelativeTime.duration(session.totalDuration)) }
        return parts.joined(separator: " · ")
    }

    /// What the lecture holds, the course last so a long name is what gets cut:
    /// "Today · 1 h 42 min · 13 questions · 2 photos · Heuristic".
    static func details(_ session: Session, model: AppModel, showsCourse: Bool) -> String {
        var parts = [RelativeTime.day(session.date)]
        if session.totalDuration > 0 { parts.append(RelativeTime.duration(session.totalDuration)) }
        let questions = model.text("questions.md", in: session).map(NoteDocument.questionCount) ?? 0
        if questions > 0 { parts.append(plural("count.questions", questions)) }
        if !session.photos.isEmpty { parts.append(plural("count.photos", session.photos.count)) }
        if showsCourse { parts.append(model.course(session.courseID)?.shortName ?? L("session.meeting")) }
        return parts.joined(separator: " · ")
    }
}

/// "%ld questions" or, for one, the `.one` form; Turkish has a single form for both.
func plural(_ key: String, _ count: Int) -> String {
    L(count == 1 ? "\(key).one" : key, count)
}

enum RelativeTime {
    /// "Pzt" or "Pazartesi" for an ISO weekday (1 = Monday).
    static func weekday(_ iso: Int, short: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        // ISO counts from Monday, the formatter from Sunday
        let symbols = short ? formatter.shortStandaloneWeekdaySymbols : formatter.standaloneWeekdaySymbols
        return (symbols?[iso % 7] ?? "").localizedCapitalized
    }

    static func dayAndTime(_ date: Date) -> String {
        "\(day(date)) \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L("time.today") }
        if calendar.isDateInTomorrow(date) { return L("time.tomorrow") }
        if calendar.isDateInYesterday(date) { return L("time.yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func until(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// "1 sa 42 dk", "42 dk", "35 sn"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return L("time.seconds", total) }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L("time.minutes", minutes) }
        return L("time.hoursMinutes", minutes / 60, minutes % 60)
    }
}
