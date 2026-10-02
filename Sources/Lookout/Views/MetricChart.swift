import LookoutCore
import SwiftUI

/// Draw whole paths rather than a view/mark for every sample. No display-link or animation loop.
struct MetricChart: View {
    let metric: Metric
    let history: [HistoryPoint]
    let end: Date
    let color: Color
    private var upperBound: Double {
        if metric == .power { return ChartData.energyUpperBound(history: history) }
        guard (metric == .network || metric == .disk) else { return 100 }
        return ChartData.rateUpperBound(history: history)
    }
    var body: some View {
        let bound = upperBound
        HStack(spacing: 5) {
            Canvas(rendersAsynchronously: true) { context, size in
                var grid = Path()
                for fraction in [0.0, 0.5, 1.0] {
                    let y = max(0.5, min(size.height - 0.5, size.height * fraction))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                drawSeries(context: &context, size: size, upper: bound, secondary: false, color: color, fill: true)
                if (metric == .network || metric == .disk) {
                    drawSeries(context: &context, size: size, upper: bound, secondary: true, color: .orange, fill: false)
                }
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(axisLabel(bound))
                Spacer(minLength: 0)
                Text(axisLabel(bound / 2))
                Spacer(minLength: 0)
                Text(axisLabel(0))
            }.font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(width: (metric == .network || metric == .disk || metric == .power) ? 48 : 22, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) 최근 5분 그래프")
        .accessibilityValue(history.last?.primary.map { (metric == .network || metric == .disk) ? ValueFormat.rate($0) : metric == .power ? ValueFormat.watts($0) : ValueFormat.percent($0) } ?? "측정값 없음")
    }
    private func axisLabel(_ value: Double) -> String {
        (metric == .network || metric == .disk) ? ValueFormat.rate(value) : metric == .power ? ValueFormat.watts(value) : "\(Int(value))"
    }
    private func drawSeries(context: inout GraphicsContext, size: CGSize, upper: Double,
                            secondary: Bool, color: Color, fill: Bool) {
        let start = end.addingTimeInterval(-300)
        let segments = Dictionary(grouping: history.filter { $0.date >= start && $0.date <= end && $0.primary != nil }, by: \.segment)
        for segment in segments.values {
            let coordinates: [CGPoint] = segment.compactMap { point in
                guard let value = secondary ? point.secondary : point.primary else { return nil }
                return CGPoint(x: point.date.timeIntervalSince(start) / 300 * size.width,
                               y: size.height * (1 - min(upper, max(0, value)) / upper))
            }
            guard let first = coordinates.first, let last = coordinates.last else { continue }
            var line = Path()
            line.move(to: first)
            for coordinate in coordinates.dropFirst() { line.addLine(to: coordinate) }
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.12)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            if coordinates.count == 1 {
                context.fill(Path(ellipseIn: CGRect(x: first.x - 1, y: first.y - 1, width: 2, height: 2)), with: .color(color))
            }
        }
    }
}
