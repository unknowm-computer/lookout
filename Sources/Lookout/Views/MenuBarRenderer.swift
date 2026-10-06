import AppKit
import LookoutCore

/// Each enabled metric owns a constant width, including missing readings and unit changes.
/// A template image lets macOS supply the correct menu-bar foreground in both appearances.
@MainActor enum MenuBarRenderer {
    private struct Cell {
        let text: String
        let width: CGFloat
        var alignment: NSTextAlignment = .right
        var lowerText: String? = nil
        var pressureRow: Bool? = nil
        var storageRow: Bool? = nil
        var pairedIndicators = false
        var metric: Metric? = nil
        var lowerMetric: Metric? = nil
    }

    struct HighlightedValue {
        let metric: Metric
        let text: String
        let frame: NSRect
        let font: NSFont
        let alignment: NSTextAlignment
    }

    struct Presentation {
        let image: NSImage
        /// Coordinates use the image's unflipped, bottom-left origin.
        let pressureFrame: NSRect?
        let storageFrame: NSRect?
        let highlightedValues: [HighlightedValue]
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let height: CGFloat = 22
    private static let metricGap: CGFloat = 12
    private static let percentWidth = width("100%")
    private static let numberWidth = width("999.9", font: networkFont)
    private static let unitWidth = ["B/s", "KB/s", "MB/s", "GB/s"].map { width($0, font: networkFont) }.max()!
    private static let arrowWidth = max(width("↓", font: networkFont), width("↑", font: networkFont))

    static func image(metrics: [Metric], readings: [Metric: MetricReading],
                      showAlertSlot: Bool = false, hasAlert: Bool = false,
                      compact: Bool = false, grouping: MenuBarGrouping = MenuBarGrouping(),
                      values: MenuBarValuePreferences = MenuBarValuePreferences()) -> NSImage {
        presentation(metrics: metrics, readings: readings, showAlertSlot: showAlertSlot, hasAlert: hasAlert,
                     compact: compact, grouping: grouping, values: values).image
    }

    static func presentation(metrics: [Metric], readings: [Metric: MetricReading],
                      showAlertSlot: Bool = false, hasAlert: Bool = false,
                      compact: Bool = false, grouping: MenuBarGrouping = MenuBarGrouping(),
                      values: MenuBarValuePreferences = MenuBarValuePreferences(),
                      alerting: Set<Metric> = []) -> Presentation {
        var cells: [Cell] = []
        if showAlertSlot { cells.append(Cell(text: hasAlert ? "!" : "", width: 4, alignment: .left)) }
        let units = grouping.units(metrics: metrics)
        for unit in units {
            if !cells.isEmpty { cells.append(Cell(text: "", width: compact ? 4 : metricGap)) }
            if unit.metrics.count == 2 {
                let upper = unit.metrics[0], lower = unit.metrics[1]
                cells.append(Cell(text: upper.menuTitle,
                    width: max(width(upper.menuTitle, font: networkFont), width(lower.menuTitle, font: networkFont)) + 4,
                    alignment: .left, lowerText: lower.menuTitle))
                cells.append(Cell(text: text(metric: upper, value: readings[upper]?.value, values: values),
                    width: max(valueWidth(metric: upper, values: values, font: networkFont),
                               valueWidth(metric: lower, values: values, font: networkFont)),
                    lowerText: text(metric: lower, value: readings[lower]?.value, values: values),
                    metric: upper, lowerMetric: lower))
                let pressureRow: Bool? = upper == .memory ? true : (lower == .memory ? false : nil)
                let storageRow: Bool? = values.storage.capacity == .used ? nil :
                    (upper == .ssd ? false : (lower == .ssd ? true : nil))
                if pressureRow != nil || storageRow != nil {
                    cells.append(Cell(text: "", width: 10, pressureRow: pressureRow, storageRow: storageRow,
                                      pairedIndicators: true))
                }
                continue
            }
            let metric = unit.metrics[0]
            let value = readings[metric]?.value
            switch metric {
            case .cpu, .gpu:
                cells += percentCells(metric: metric, value: value?.primary, compact: compact)
            case .memory, .ssd:
                if !compact { cells.append(Cell(text: metric.menuTitle, width: width(metric.menuTitle) + 4, alignment: .left)) }
                cells.append(Cell(text: values.text(for: metric, value: value),
                                  width: valueWidth(metric: metric, values: values, font: font), metric: metric))
                if metric == .memory { cells.append(Cell(text: "", width: 10, pressureRow: false)) }
                if metric == .ssd, values.storage.capacity == .available {
                    cells.append(Cell(text: "", width: 10, storageRow: false))
                }
            case .power:
                if !compact { cells.append(Cell(text: "ENG", width: width("ENG") + 4, alignment: .left)) }
                cells.append(Cell(text: value?.primary.map(ValueFormat.watts) ?? "—", width: width("999.9 W"), metric: metric))
            case .disk:
                if case .disk(let disk) = value {
                    cells += rateCells(upload: disk.activity?.read, download: disk.activity?.write, upperLabel: "R", lowerLabel: "W")
                } else {
                    cells += rateCells(upload: nil, download: nil, upperLabel: "R", lowerLabel: "W")
                }
            case .network:
                if case .network(let network) = value {
                    cells += rateCells(upload: network.upload, download: network.download)
                } else {
                    cells += rateCells(upload: nil, download: nil)
                }
            }
        }

        // Paired units and rate labels identify themselves.
        let labeledMetrics: [Metric] = [.network, .disk]
        let symbolMetric = compact && metrics.count == 1 && !labeledMetrics.contains(metrics[0]) ? metrics[0] : nil
        let symbolWidth: CGFloat = symbolMetric == nil ? 0 : 20
        let image = NSImage(size: NSSize(width: symbolWidth + cells.reduce(0) { $0 + $1.width }, height: height))
        image.lockFocus()
        if let metric = symbolMetric, let symbol = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: metric.title) {
            let configured = symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? symbol
            let scale = min(16 / configured.size.width, 16 / configured.size.height)
            let size = NSSize(width: configured.size.width * scale, height: configured.size.height * scale)
            configured.draw(in: NSRect(x: (16 - size.width) / 2, y: (height - size.height) / 2,
                                      width: size.width, height: size.height))
        }
        var x = symbolWidth
        var pressureFrame: NSRect?
        var storageFrame: NSRect?
        var highlightedValues: [HighlightedValue] = []
        for cell in cells {
            if let upperRow = cell.pressureRow {
                let y: CGFloat = cell.pairedIndicators ? (upperRow ? 14 : 3) : 8
                pressureFrame = NSRect(x: x + 3, y: y, width: 6, height: 6)
            }
            if let lowerRow = cell.storageRow {
                let y: CGFloat = cell.pairedIndicators ? (lowerRow ? 3 : 14) : 8
                storageFrame = NSRect(x: x + 3, y: y, width: 6, height: 6)
            }
            func drawRow(_ text: String, metric: Metric?, font: NSFont, bottom: CGFloat, rowHeight: CGFloat) {
                if let metric, alerting.contains(metric), !text.isEmpty {
                    highlightedValues.append(HighlightedValue(metric: metric, text: text,
                        frame: NSRect(x: x, y: bottom, width: cell.width, height: rowHeight),
                        font: font, alignment: cell.alignment))
                } else {
                    draw(text, cell: cell, font: font, x: x, bottom: bottom, rowHeight: rowHeight)
                }
            }
            if let lowerText = cell.lowerText {
                drawRow(cell.text, metric: cell.metric, font: networkFont, bottom: height / 2, rowHeight: height / 2)
                drawRow(lowerText, metric: cell.lowerMetric, font: networkFont, bottom: 0, rowHeight: height / 2)
            } else {
                drawRow(cell.text, metric: cell.metric, font: font, bottom: 0, rowHeight: height)
            }
            x += cell.width
        }
        image.unlockFocus()
        image.isTemplate = true
        return Presentation(image: image, pressureFrame: pressureFrame, storageFrame: storageFrame,
                            highlightedValues: highlightedValues)
    }

    private static func text(metric: Metric, value: ReadingValue?, values: MenuBarValuePreferences) -> String {
        if metric == .memory || metric == .ssd { return values.text(for: metric, value: value) }
        if metric == .power { return value?.primary.map(ValueFormat.watts) ?? "—" }
        return value?.primary.map(ValueFormat.percent) ?? "—"
    }
    private static func valueWidth(metric: Metric, values: MenuBarValuePreferences, font: NSFont) -> CGFloat {
        if metric == .power { return width("999.9 W", font: font) }
        guard metric == .memory || metric == .ssd, !values.mode(for: metric).isPercentage else {
            return width("100%", font: font)
        }
        // Reserve the largest unit and digit count independently of the current reading.
        let templates = metric == .memory ? ["9999.9 GiB", "9999.9 MiB"]
            : ["9999 GB", "9999 TB", "99.9 GB", "99.9 TB", "999 MB", "99.9 MB", "99.9 KB"]
        return templates.map { width($0, font: font) }.max()!
    }

    private static func percentCells(metric: Metric, value: Double?, compact: Bool) -> [Cell] {
        let label = metric.menuTitle
        let labelCells = compact ? [] : [Cell(text: label, width: width(label) + 4, alignment: .left)]
        return labelCells + [Cell(text: value.map(ValueFormat.percent) ?? "—", width: percentWidth, metric: metric)]
    }
    private static func rateCells(upload: Double?, download: Double?, upperLabel: String = "↑", lowerLabel: String = "↓") -> [Cell] {
        let upper = upload.map(ValueFormat.rate) ?? "—"
        let lower = download.map(ValueFormat.rate) ?? "—"
        return [Cell(text: upperLabel, width: upperLabel == "R" ? max(width("R", font: networkFont), width("W", font: networkFont)) : arrowWidth, alignment: .left, lowerText: lowerLabel),
                // Right-align the whole value so short units end at the same edge as MB/s.
                Cell(text: upper, width: numberWidth + 2 + unitWidth, lowerText: lower)]
    }

    static func draw(_ value: HighlightedValue, color: NSColor) {
        draw(value.text, cell: Cell(text: value.text, width: value.frame.width, alignment: value.alignment),
             font: value.font, x: value.frame.minX, bottom: value.frame.minY, rowHeight: value.frame.height, color: color)
    }
    private static func draw(_ text: String, cell: Cell, font: NSFont, x: CGFloat, bottom: CGFloat, rowHeight: CGFloat,
                             color: NSColor = .black) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = cell.alignment
        let naturalWidth = width(text, font: font)
        // Keep rare extreme values inside their slot without enlarging the status item.
        let scale = naturalWidth > cell.width ? cell.width / naturalWidth : 1
        let textHeight = ceil((text as NSString).size(withAttributes: [.font: font]).height)
        let y = bottom + floor((rowHeight - textHeight) / 2)
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: scale, y: 1)
        (text as NSString).draw(in: NSRect(x: 0, y: 0, width: cell.width / scale, height: textHeight),
                               withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        context.restoreGState()
    }

    private static func width(_ text: String, font: NSFont? = nil) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font ?? Self.font]).width)
    }
}
