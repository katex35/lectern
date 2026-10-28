import LecternCore
import SwiftUI

enum Theme {
    static let ink = Color(hex: 0x0D0D0D)
    static let secondary = Color(hex: 0x5D5D5D)
    static let tertiary = Color(hex: 0x6B6B6B)
    static let sidebar = Color(hex: 0xF9F9F9)
    static let hover = Color(hex: 0xEFEFEF)
    static let selected = Color(hex: 0xECECEC)
    static let line = Color(hex: 0xECECEC)
    static let field = Color(hex: 0xE3E3E3)
    static let card = Color(hex: 0xF6F6F6)
    static let record = Color(hex: 0xE5484D)

    /// Ease-out used for screen changes and things moving into place.
    static let ease = Animation.timingCurve(0.22, 0.9, 0.24, 1, duration: 0.42)
    static let quick = Animation.timingCurve(0.22, 0.9, 0.24, 1, duration: 0.24)

    /// A course's color: its own, or one of six by its position.
    static func color(of course: Course?, among courses: [Course]) -> Color {
        if let hex = course?.colorHex.flatMap({ UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) }) {
            return Color(hex: hex)
        }
        guard let course, let index = courses.firstIndex(of: course) else { return Color(hex: 0x64748B) }
        return palette[index % palette.count]
    }

    static let palette: [Color] = [0xF59E0B, 0x3B82F6, 0x10B981, 0x8B5CF6, 0xEC4899, 0x64748B].map { Color(hex: $0) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The app's table in the user's language. Picked by hand because a binary started outside an app
/// bundle would otherwise always get the development language.
private let localizedBundle: Bundle = {
    let preferred = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: Locale.preferredLanguages)
    if let code = preferred.first, let path = Bundle.module.path(forResource: code, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    return .module
}()

/// A localized string from the app's own tables.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}

extension Course {
    /// "Data Science" for "Data Science (CSE 5223)": the code is noise in narrow places.
    var shortName: String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex else { return name }
        let trimmed = name[..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }
}

/// Rows and plain buttons: a soft background on hover, a small press.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, radius: radius)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let selected: Bool
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Theme.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Black, white or outlined capsules.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, danger }
    var kind: Kind = .primary
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(kind == .outline ? Theme.ink : .white)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Capsule().fill(kind == .primary ? Theme.ink : kind == .danger ? Theme.record : .white))
            .overlay(Capsule().strokeBorder(kind == .outline ? Theme.field : .clear))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// An icon-only button with a hover square.
struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: 8))
        .accessibilityLabel(label)
        .help(label)
    }
}

extension TimeInterval {
    /// 07:05 or 1:02:05
    var clock: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

}
