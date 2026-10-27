import AppKit
import Foundation
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func temperatureAlertOverridesBandColorInSingleAndPairedMenuItems() {
    let reading = CoolingReading(cpu: 80, gpu: 75, fans: [], band: .warm, uptime: 0, canControl: false)
    for pairs in [[], [MenuBarPair(.cpu, .cooling)], [MenuBarPair(.cooling, .memory)]] {
        let grouping = MenuBarGrouping(pairs: pairs)
        let metrics = pairs.first.map { [$0.upper, $0.lower] } ?? [.cooling]
        let normal = MenuBarRenderer.presentation(metrics: metrics, readings: [
            .cooling: MetricReading(metric: .cooling, date: Date(), value: .cooling(reading))
        ], compact: true, grouping: grouping)
        let alerting = MenuBarRenderer.presentation(metrics: metrics, readings: [
            .cooling: MetricReading(metric: .cooling, date: Date(), value: .cooling(reading))
        ], compact: true, grouping: grouping, alerting: [.cooling])
        #expect(alerting.image.size == normal.image.size)
        let temperatures = alerting.highlightedValues.filter { $0.metric == .cooling }
        #expect(temperatures.count == 2 && temperatures.allSatisfy { $0.color == .systemRed })
        #expect(!alerting.coloredSymbols.isEmpty && alerting.coloredSymbols.allSatisfy { $0.color == .systemRed })
        #expect(normal.highlightedValues.filter { $0.metric == .cooling }.allSatisfy { $0.color == .systemOrange })
    }
}

@Test @MainActor func coolingTemperatureColorsAndWidthsRemainStableIncludingPairedRows() {
    let date = Date()
    for grouping in [MenuBarGrouping(pairs: []), MenuBarGrouping(pairs: [MenuBarPair(.cpu, .cooling)])] {
        let metrics: [Metric] = grouping.pairs.isEmpty ? [.cooling] : [.cpu, .cooling]
        let empty = MenuBarRenderer.presentation(metrics: metrics, readings: [:], compact: true, grouping: grouping)
        for band in [CoolingTemperatureBand.normal, .warm, .hot] {
            let value = CoolingReading(cpu: band == .normal ? 45 : 95, gpu: 40, fans: [], band: band, uptime: 1, canControl: false)
            let readings: [Metric: MetricReading] = [.cooling: MetricReading(metric: .cooling, date: date, value: .cooling(value))]
            let image = MenuBarRenderer.presentation(metrics: metrics, readings: readings, compact: true, grouping: grouping)
            #expect(image.image.size == empty.image.size)
            #expect(image.image.isTemplate)
            #expect(image.highlightedValues.count == (band == .normal ? 0 : 2))
            if band != .normal {
                #expect(image.highlightedValues[0].color == (band == .warm ? .systemOrange : .systemRed))
            }
        }
    }
}

@Test @MainActor func coolingAccentDrawsBothThermometerAndTemperatureWithoutChangingHitTesting() throws {
    for band in [CoolingTemperatureBand.warm, .hot] {
        let reading = CoolingReading(cpu: 95, gpu: 70, fans: [], band: band, uptime: 0, canControl: false)
        let presentation = MenuBarRenderer.presentation(metrics: [.cooling], readings: [
            .cooling: MetricReading(metric: .cooling, date: Date(), value: .cooling(reading))
        ], compact: true)
        #expect(presentation.coloredSymbols.count == 1)
        #expect(presentation.highlightedValues.count == 2)
        let image = NSImage(size: presentation.image.size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        MenuBarAccentOverlay.paint(presentation: presentation, pressure: nil, storageMode: .available)
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        for rect in [presentation.coloredSymbols[0].frame] + presentation.highlightedValues.map(\.frame) {
            var coloredPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let point = NSPoint(x: Double(x) / Double(bitmap.pixelsWide) * image.size.width,
                                        y: (1 - Double(y) / Double(bitmap.pixelsHigh)) * image.size.height)
                    guard rect.contains(point), let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if pixel.redComponent > pixel.blueComponent + 0.3 { coloredPixels += 1 }
                }
            }
            #expect(coloredPixels > 0)
        }
    }
    #expect(MenuBarAccentOverlay(frame: .zero).hitTest(.zero) == nil)
}

@Test @MainActor func coolingTemperaturesStackAloneAndFitInlineInEitherGroupRow() {
    let value = CoolingReading(cpu: 95, gpu: 70, fans: [], band: .hot, uptime: 0, canControl: false)
    let readings: [Metric: MetricReading] = [.cooling: MetricReading(metric: .cooling, date: Date(), value: .cooling(value))]
    for compact in [false, true] {
        let single = MenuBarRenderer.presentation(metrics: [.cooling], readings: readings, compact: compact)
        #expect(single.highlightedValues.map(\.text) == ["95°C", "70°C"])
        #expect(single.highlightedValues[0].frame.minY > single.highlightedValues[1].frame.minY)
        #expect(single.highlightedValues[0].frame.minX == single.highlightedValues[1].frame.minX)
        for pair in [MenuBarPair(.cooling, .power), MenuBarPair(.power, .cooling)] {
            let grouping = MenuBarGrouping(pairs: [pair])
            let grouped = MenuBarRenderer.presentation(metrics: pair.metrics, readings: readings, compact: compact, grouping: grouping)
            #expect(grouped.highlightedValues.count == 2)
            #expect(grouped.highlightedValues.map(\.text) == ["95°", "70°"])
            #expect(grouped.highlightedValues[0].font.pointSize == single.highlightedValues[0].font.pointSize)
            #expect(grouped.highlightedValues[0].font.pointSize == 9)
            #expect(grouped.highlightedValues[0].frame.minY == (pair.upper == .cooling ? 11 : 0))
            #expect(grouped.coloredSymbols.count == 2)
            for index in 0..<2 {
                #expect(grouped.coloredSymbols[index].frame.height <= 11)
                #expect(grouped.coloredSymbols[index].frame.minY >= grouped.highlightedValues[index].frame.minY)
                #expect(grouped.coloredSymbols[index].frame.maxY <= grouped.highlightedValues[index].frame.maxY)
                #expect(grouped.coloredSymbols[index].frame.maxX < grouped.highlightedValues[index].frame.minX)
            }
            #expect(grouped.highlightedValues[0].frame.minY == grouped.highlightedValues[1].frame.minY)
            #expect(grouped.coloredSymbols[1].frame.minX - grouped.highlightedValues[0].frame.maxX >= 16)
            let empty = MenuBarRenderer.presentation(metrics: pair.metrics, readings: [:], compact: compact, grouping: grouping)
            #expect(grouped.image.size == empty.image.size)
            let fallback = MenuBarRenderer.presentation(metrics: [.cooling], readings: readings, compact: compact, grouping: grouping)
            #expect(fallback.highlightedValues.map(\.text) == ["95°C", "70°C"])
            #expect(fallback.image.size == single.image.size)
        }
    }
    if let directory = ProcessInfo.processInfo.environment["LOOKOUT_RENDER_OUTPUT"] {
        let variants = [MenuBarPair(.cooling, .power), MenuBarPair(.power, .cooling)]
        let samples = [MenuBarRenderer.presentation(metrics: [.cooling], readings: readings)] + variants.map {
            MenuBarRenderer.presentation(metrics: $0.metrics, readings: readings, grouping: MenuBarGrouping(pairs: [$0]))
        }
        let sheet = NSImage(size: NSSize(width: 240, height: 110))
        sheet.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 240, height: 110).fill()
        for (index, sample) in samples.enumerated() {
            NSGraphicsContext.current!.cgContext.saveGState()
            NSGraphicsContext.current!.cgContext.translateBy(x: 12, y: CGFloat(2 - index) * 34 + 9)
            sample.image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            MenuBarAccentOverlay.paint(presentation: sample, pressure: nil, storageMode: .available)
            NSGraphicsContext.current!.cgContext.restoreGState()
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu-cooling-layout.png"))
        }
    }
}
