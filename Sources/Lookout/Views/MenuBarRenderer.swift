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
                      compact: Bool = false) -> NSImage {
        var cells: [Cell] = []
        if showAlertSlot { cells.append(Cell(text: hasAlert ? "!" : "", width: 4, alignment: .left)) }
        for metric in metrics {
            if !cells.isEmpty { cells.append(Cell(text: "", width: compact ? 4 : metricGap)) }
            let value = readings[metric]?.value
            switch metric {
            case .cpu, .memory, .gpu:
                let label = compact ? "" : metric.menuTitle
                let percent = value?.primary
                let text = percent.map(ValueFormat.percent) ?? "—"
                if !compact { cells.append(Cell(text: label, width: width(label) + 4, alignment: .left)) }
                cells.append(Cell(text: text, width: percentWidth))
            case .power:
                if !compact { cells.append(Cell(text: "ENG", width: width("ENG") + 4, alignment: .left)) }
                cells.append(Cell(text: value?.primary.map(ValueFormat.watts) ?? "—", width: width("999.9 W")))
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

        // Two-line rate labels already identify network and disk. Percent/power slots use a symbol.
        let symbolMetric = compact && metrics.count == 1 && ![Metric.network, .disk].contains(metrics[0]) ? metrics[0] : nil
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
        for cell in cells {
            if let lowerText = cell.lowerText {
                draw(cell.text, cell: cell, font: networkFont, x: x, bottom: height / 2, rowHeight: height / 2)
                draw(lowerText, cell: cell, font: networkFont, x: x, bottom: 0, rowHeight: height / 2)
            } else {
                draw(cell.text, cell: cell, font: font, x: x, bottom: 0, rowHeight: height)
            }
            x += cell.width
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func rateCells(upload: Double?, download: Double?, upperLabel: String = "↑", lowerLabel: String = "↓") -> [Cell] {
        let upper = upload.map(ValueFormat.rate) ?? "—"
        let lower = download.map(ValueFormat.rate) ?? "—"
        return [Cell(text: upperLabel, width: upperLabel == "R" ? max(width("R", font: networkFont), width("W", font: networkFont)) : arrowWidth, alignment: .left, lowerText: lowerLabel),
                // Right-align the whole value so short units end at the same edge as MB/s.
                Cell(text: upper, width: numberWidth + 2 + unitWidth, lowerText: lower)]
    }

    private static func draw(_ text: String, cell: Cell, font: NSFont, x: CGFloat, bottom: CGFloat, rowHeight: CGFloat) {
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
                               withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        context.restoreGState()
    }

    private static func width(_ text: String, font: NSFont? = nil) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font ?? Self.font]).width)
    }
}
