import LecternCore
import SwiftUI

/// What the live helper puts under the menu bar during a call: what was asked, in the user's own
/// language, and something short to say.
struct HelperNotice: View {
    enum Content {
        /// The key was pressed; the answer is on its way.
        case listening
        /// Something may have been asked: one line, the key opens the answer.
        case offer(HelperReply)
        case answer(HelperReply)
        /// Nothing could be shown, and why.
        case problem(String)
    }

    let content: Content
    var notUseful: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content {
            case .listening:
                row(symbol: "ear", title: L("helper.listening"), detail: nil)
            case .problem(let message):
                row(symbol: "exclamationmark.circle", title: L("helper.problem"), detail: message)
                buttons(showsNotUseful: false)
            case .offer(let reply):
                row(symbol: "questionmark.bubble", title: L("helper.offer"), detail: reply.gist.isEmpty ? reply.question : reply.gist)
                HStack {
                    Text(L("helper.offer.hint", GlobalHotKey.helperKey.label))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                }
            case .answer(let reply):
                row(symbol: "questionmark.bubble.fill", title: reply.gist.isEmpty ? reply.question : reply.gist,
                    detail: reply.gist.isEmpty || reply.question == reply.gist ? nil : reply.question)
                if let answer = reply.answer {
                    VStack(alignment: .leading, spacing: 5) {
                        if !answer.headline.isEmpty {
                            Text(answer.headline)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        ForEach(Array(answer.points.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "•").foregroundStyle(Theme.tertiary)
                                Text(point).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                } else if !reply.heard.isEmpty {
                    Text(reply.heard)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(4)
                }
                buttons(showsNotUseful: notUseful != nil)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        .environment(\.colorScheme, .light)
    }

    private func row(symbol: String, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func buttons(showsNotUseful: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if showsNotUseful, let notUseful {
                Button(L("helper.notUseful"), action: notUseful)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 26))
            }
            Button(L("helper.close"), action: close)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 26))
        }
    }
}
