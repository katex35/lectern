import LecternCore
import SwiftUI

/// Every recording as cards, newest first and grouped by week. A course chip narrows it to that
/// course, which is the course's own page: its hours, dates and lectures.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    let filter: ArchiveFilter
    @State private var query = ""
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                    .enter(appeared, delay: 0)
                chips
                    .enter(appeared, delay: 0.04)
                if case .course(let id) = filter, let course = model.course(id) {
                    CourseStrip(course: course)
                        .enter(appeared, delay: 0.06)
                }
                let groups = self.groups
                if groups.isEmpty {
                    Text(query.isEmpty ? L("archive.empty") : L("archive.noMatch"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 4)
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                                ForEach(group.sessions, id: \.ref) { session in
                                    SessionCard(session: session, coverHeight: 110,
                                                meta: SessionText.details(session, model: model, showsCourse: filter == .all))
                                }
                            }
                        }
                    }
                    .enter(appeared, delay: 0.1)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { appeared = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if case .course(let id) = filter, let course = model.course(id) {
                CoverView(course: course, width: 30, height: 30, radius: 8)
            }
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .kerning(-0.5)
                .lineLimit(2)
                .help(courseName ?? "")
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                TextField(L("archive.search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("archive.clear"))
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 240, height: 32)
            .background(Capsule().fill(Color(hex: 0xF4F4F4)))
        }
    }

    private var title: String {
        switch filter {
        case .all: return L("archive.title")
        case .course(let id): return model.course(id)?.shortName ?? L("archive.title")
        case .meetings: return L("archive.meetings")
        }
    }

    /// The full name with its code, shown on hover where the title leaves the code out.
    private var courseName: String? {
        if case .course(let id) = filter { return model.course(id)?.name }
        return nil
    }

    private var chips: some View {
        FlowLayout(spacing: 6) {
            FilterChip(label: L("archive.all"), course: nil, on: filter == .all) { model.go(to: .archive(.all)) }
            ForEach(model.courses) { course in
                FilterChip(label: course.shortName, course: course, on: filter == .course(course.id)) {
                    model.go(to: .archive(.course(course.id)))
                }
            }
            if model.sessions.contains(where: { $0.kind == .meeting }) {
                FilterChip(label: L("archive.meetings"), course: nil, on: filter == .meetings) { model.go(to: .archive(.meetings)) }
            }
        }
    }

    private struct Group {
        let title: String
        let sessions: [Session]
    }

    /// This week, last week, then month by month.
    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
        let lastWeek = thisWeek.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0.start.addingTimeInterval(-86_400)) }
        var result: [Group] = []
        for session in matching {
            let title: String
            if thisWeek?.contains(session.date) == true {
                title = L("home.thisWeek")
            } else if lastWeek?.contains(session.date) == true {
                title = L("archive.lastWeek")
            } else {
                // the year only when it is not this one
                let sameYear = calendar.isDate(session.date, equalTo: now, toGranularity: .year)
                title = (sameYear ? session.date.formatted(.dateTime.month(.wide))
                                  : session.date.formatted(.dateTime.month(.wide).year())).localizedCapitalized
            }
            if result.last?.title == title {
                result[result.count - 1] = Group(title: title, sessions: result[result.count - 1].sessions + [session])
            } else {
                result.append(Group(title: title, sessions: [session]))
            }
        }
        return result
    }

    /// The filter's sessions, and with a query only those whose title, course or notes contain it.
    private var matching: [Session] {
        let sessions = model.sessions.filter(filter.includes)
        let words = LibrarySearch.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { session in
            let text = LibrarySearch.fold([SessionText.title(session, model: model), model.course(session.courseID)?.name ?? "",
                                           model.text("notes.md", in: session) ?? ""].joined(separator: " "))
            return words.allSatisfy(text.contains)
        }
    }
}

struct FilterChip: View {
    let label: String
    let course: Course?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let course {
                    CoverView(course: course, width: 18, height: 18, radius: 9)
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 190)
            .foregroundStyle(on ? .white : Theme.ink)
            .padding(.leading, course == nil ? 12 : 5)
            .padding(.trailing, 12)
            .frame(height: 28)
            .background(Capsule().fill(on ? Theme.ink : .white))
            .overlay(Capsule().strokeBorder(on ? Theme.ink : Theme.field))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: on)
        .help(course?.name ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A course's hours and coming dates in one line, with recording and editing at its end.
private struct CourseStrip: View {
    @Environment(AppModel.self) private var model
    let course: Course

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
            Text(summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button { model.record(course) } label: {
                Label(L("home.record"), systemImage: "mic.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 28))
            IconButton(systemName: "pencil", label: L("course.edit")) { model.edit(course) }
        }
    }

    /// "Pzt 09:55 · Çar 13:30 · Vize 13 Kasım"
    private var summary: String {
        var parts = course.slots.filter(\.isValid).sorted { ($0.weekday, $0.start) < ($1.weekday, $1.start) }
            .map { "\(RelativeTime.weekday($0.weekday)) \($0.start)" }
        parts += CourseDate.upcoming(in: [course], from: Date(), days: 120).prefix(2)
            .map { "\($0.date.title.isEmpty ? L("course.kind.\($0.date.kind.rawValue)") : $0.date.title) \($0.date.date.formatted(.dateTime.day().month(.wide)))" }
        if let instructor = course.instructor, !instructor.isEmpty { parts.append(instructor) }
        return parts.isEmpty ? L("archive.noSchedule") : parts.joined(separator: " · ")
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
