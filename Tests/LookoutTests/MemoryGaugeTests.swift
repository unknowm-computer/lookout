import AppKit
import LookoutCore
@testable import Lookout
import SwiftUI
import Testing

@Test func gaugeTooltipFollowsPointerAndStaysInsideViewport() {
    let size = CGSize(width: 150, height: 22)
    let bounds = CGRect(x: 6, y: 6, width: 328, height: 288)
    let first = UsageTooltipPlacement.center(pointer: CGPoint(x: 130, y: 120), size: size, bounds: bounds)
    let moved = UsageTooltipPlacement.center(pointer: CGPoint(x: 170, y: 160), size: size, bounds: bounds)
    #expect(first == CGPoint(x: 130, y: 99))
    #expect(moved == CGPoint(x: 170, y: 139))
    for pointer in [CGPoint(x: 8, y: 120), CGPoint(x: 332, y: 120), CGPoint(x: 130, y: 8), CGPoint(x: 130, y: 292)] {
        let center = UsageTooltipPlacement.center(pointer: pointer, size: size, bounds: bounds)
        let tooltip = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        #expect(bounds.contains(tooltip))
    }
    let atTop = UsageTooltipPlacement.center(pointer: CGPoint(x: 130, y: 8), size: size, bounds: bounds)
    #expect(atTop.y - size.height / 2 == 18)
}

@Test func memoryGaugeHoverSelectsArcSegmentsAndIgnoresCenterAndMissingData() {
    let geometry = UsageGaugeGeometry(size: CGSize(width: 108, height: 66))
    let segments = [0.25, 0.125, 0.375, 0.25].enumerated().map { index, fraction in
        UsageBarSegment(id: String(index), title: String(index), fraction: fraction, color: .purple, summary: "")
    }
    func point(_ fraction: Double, radius: CGFloat = 47) -> CGPoint {
        let angle = .pi * (1 + fraction)
        return CGPoint(x: geometry.center.x + radius * cos(angle), y: geometry.center.y + radius * sin(angle))
    }
    for (fraction, id) in [(0.1, "0"), (0.3, "1"), (0.6, "2"), (0.9, "3")] {
        #expect(geometry.segmentID(at: point(fraction), segments: segments) == id)
    }
    #expect(geometry.segmentID(at: CGPoint(x: 7, y: 63), segments: segments) == "0")
    #expect(geometry.segmentID(at: CGPoint(x: 101, y: 63), segments: segments) == "3")
    #expect(geometry.segmentID(at: point(0.3, radius: 51), segments: segments) == "1")
    #expect(geometry.segmentID(at: geometry.center, segments: segments) == nil)
    #expect(geometry.segmentID(at: point(0.3, radius: 60), segments: segments) == nil)
    #expect(geometry.segmentID(at: point(0.3), segments: []) == nil)
    #expect(geometry.segmentID(at: point(0.9), segments: Array(segments.prefix(2))) == nil)
}

@Test @MainActor func memoryGaugeRendersAppWiredAndCompressedSegmentsInBothThemes() throws {
    let memory = MemoryReading(total: 32, app: 8, wired: 4, compressed: 12, swap: 0, swapTotal: 0)
    let end = Date(timeIntervalSince1970: 1000)
    for scheme in [ColorScheme.light, .dark] {
        let view = MemoryMetricVisualization(
            reading: MetricReading(metric: .memory, date: end, value: .memory(memory)),
            history: [], end: end, style: .gauge, showsSwapDetails: false
        ).frame(width: 308).fixedSize().environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        // Only inspect the gauge; the legend and history must not satisfy these checks.
        let gauge = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 216, height: 132)))
        let pixels = NSBitmapImageRep(cgImage: gauge)
        var purple = 0, cyan = 0, orange = 0
        for y in 0..<pixels.pixelsHigh {
            for x in 0..<pixels.pixelsWide {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                if r > 0.4 && b > 0.4 && g < min(r, b) * 0.7 { purple += 1 }
                if g > 0.4 && b > 0.4 && r < min(g, b) * 0.7 { cyan += 1 }
                if r > 0.7 && g > 0.25 && b < g * 0.7 { orange += 1 }
            }
        }
        #expect(purple > 100)
        #expect(cyan > 100)
        #expect(orange > 100)
        // The rounded start must remain filled where the cap meets the arc.
        let start = try #require(pixels.colorAt(x: 14, y: 120)?.usingColorSpace(.deviceRGB))
        #expect(start.alphaComponent > 0.9)
    }
}
