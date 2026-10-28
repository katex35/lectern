import SwiftUI

/// The Lectern mark: three bars of a sound wave bending into lines of notes, with the red dot.
struct LogoMark: View {
    var size: CGFloat = 24
    var ink: Color = Theme.ink
    /// Draws the strokes in, holds, and lets them flow out again.
    var animated = false
    @State private var progress: CGFloat = 1

    var body: some View {
        let unit = size / 64
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                LogoStroke(index: index)
                    .trim(from: 0, to: progress)
                    .stroke(ink, style: StrokeStyle(lineWidth: 6 * unit, lineCap: .round, lineJoin: .round))
                    .animation(animated ? .timingCurve(0.65, 0, 0.35, 1, duration: 1.3).delay(Double(index) * 0.14) : nil,
                               value: progress)
            }
            Circle()
                .fill(Theme.record)
                .frame(width: 7.6 * unit, height: 7.6 * unit)
                .position(x: 56 * unit, y: 16 * unit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: animated) {
            guard animated else { return }
            while !Task.isCancelled {
                progress = 0
                try? await Task.sleep(nanoseconds: 80_000_000)
                progress = 1
                try? await Task.sleep(nanoseconds: 3_200_000_000)
            }
        }
    }
}

private struct LogoStroke: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let u = rect.width / 64
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        // (x of the bar, y where it turns, radius of the turn, x where the line ends)
        let spec: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(12, 16, 9, 47), (24, 30, 7, 45), (36, 44, 4, 50)]
        let (x, y, r, end) = spec[index]
        var path = Path()
        path.move(to: p(x, 54))
        path.addLine(to: p(x, y + r))
        path.addArc(tangent1End: p(x, y), tangent2End: p(x + r, y), radius: r * u)
        path.addLine(to: p(end, y))
        return path
    }
}
