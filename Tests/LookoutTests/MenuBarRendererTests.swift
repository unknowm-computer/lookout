import AppKit
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func capacityPreferencesPersistWithoutChangingCollectionOrAlerts() throws {
    let name = "LookoutTests.menuValues.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    let config = store.configuration, alerts = store.alerts
    #expect(store.menuBarValues == MenuBarValuePreferences())
    store.setMenuBarValue(.available, for: .memory)
    store.setMenuBarValue(.used, for: .ssd)
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.menuBarValues == MenuBarValuePreferences(memory: .available, storage: .used))
    #expect(store.configuration == config && store.alerts == alerts)
    store.setMenuBarValue(.used, for: .cpu)
    #expect(store.menuBarValues == restored.menuBarValues)
}

@Test @MainActor func capacityAndPercentageControlsPreserveIndependentSavedChoices() throws {
    let name = "LookoutTests.capacityControls.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    let config = store.configuration, alerts = store.alerts, charts = store.charts
    store.setMenuBarCapacity(.available, for: .memory)
    #expect(store.menuBarValues == MenuBarValuePreferences(memory: .availablePercentage))
    store.setMenuBarPercentage(true, for: .ssd)
    #expect(store.menuBarValues.storage == .availablePercentage)
    store.setMenuBarCapacity(.used, for: .ssd)
    #expect(store.menuBarValues.storage == .percentage)
    store.setMenuBarPercentage(false, for: .memory)
    #expect(store.menuBarValues.memory == .available)
    store.setMenuBarPercentage(false, for: .ssd)
    #expect(store.menuBarValues.storage == .used)
    store.setMenuBarPercentage(true, for: .memory)
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.menuBarValues == MenuBarValuePreferences(memory: .availablePercentage, storage: .used))
    store.setMenuBarCapacity(.available, for: .cpu)
    store.setMenuBarPercentage(true, for: .network)
    #expect(store.menuBarValues == restored.menuBarValues)
    #expect(store.configuration == config && store.alerts == alerts && store.charts == charts)
    #expect(restored.configuration == config && restored.alerts == alerts && restored.charts == charts)
}

@Test @MainActor func capacitySlotsKeepWidthAcrossMissingReadingsAndUnitChanges() {
    let small: [Metric: MetricReading] = [
        .memory: MetricReading(metric: .memory, date: Date(), value: .memory(MemoryReading(total: 32e9, app: 10e9, wired: 4e9, compressed: 1e9, swap: nil, pressure: .normal))),
        .ssd: MetricReading(metric: .ssd, date: Date(), value: .storage(DiskCapacityReading(name: "SSD", total: 500e9, available: 50e9)))
    ]
    let large: [Metric: MetricReading] = [
        .memory: MetricReading(metric: .memory, date: Date(), value: .memory(MemoryReading(total: 1024e9, app: 800e9, wired: 100e9, compressed: 100e9, swap: nil, pressure: .critical))),
        .ssd: MetricReading(metric: .ssd, date: Date(), value: .storage(DiskCapacityReading(name: "SSD", total: 8e12, available: 4e12)))
    ]
    for compact in [true, false] {
        for mode in CapacityMenuBarValue.allCases {
            for metrics: [Metric] in [[.memory], [.ssd], [.memory, .ssd], [.cpu, .memory, .ssd, .network]] {
                let values = MenuBarValuePreferences(memory: mode, storage: mode)
                let empty = MenuBarRenderer.presentation(metrics: metrics, readings: [:], compact: compact, values: values)
                let current = MenuBarRenderer.presentation(metrics: metrics, readings: small, compact: compact, values: values)
                let bigger = MenuBarRenderer.presentation(metrics: metrics, readings: large, compact: compact, values: values)
                #expect(empty.image.size == current.image.size && current.image.size == bigger.image.size)
                #expect(empty.image.isTemplate)
                #expect((empty.pressureFrame != nil) == metrics.contains(.memory))
                #expect((empty.storageFrame != nil) == (metrics.contains(.ssd) && [.available, .availablePercentage].contains(mode)))
                #expect(empty.storageFrame == current.storageFrame && current.storageFrame == bigger.storageFrame)
                if let frame = empty.pressureFrame {
                    #expect(NSRect(origin: .zero, size: empty.image.size).contains(frame))
                    #expect(frame == current.pressureFrame && frame == bigger.pressureFrame)
                }
            }
        }
    }
}

@Test @MainActor func warningsHighlightOnlyAffectedRowsWithoutChangingWidths() {
    let readings: [Metric: MetricReading] = [
        .cpu: MetricReading(metric: .cpu, date: Date(), value: .cpu(95)),
        .gpu: MetricReading(metric: .gpu, date: Date(), value: .gpu(GPUReading(name: "GPU", utilization: 20, renderer: nil, tiler: nil, sharedMemory: nil))),
        .memory: MetricReading(metric: .memory, date: Date(), value: .memory(MemoryReading(total: 32e9, app: 20e9, wired: 3e9, compressed: 4e9, swap: nil))),
        .ssd: MetricReading(metric: .ssd, date: Date(), value: .storage(DiskCapacityReading(name: "SSD", total: 500e9, available: 10e9)))
    ]
    let grouping = MenuBarGrouping(cpuGPU: true)
    for metric in [Metric.cpu, .gpu, .memory, .ssd] {
        for metrics in [[metric], [.cpu, .gpu], [.memory, .ssd], [.cpu, .gpu, .memory, .ssd]] where metrics.contains(metric) {
            let normal = MenuBarRenderer.presentation(metrics: metrics, readings: readings,
                showAlertSlot: true, grouping: grouping)
            let alert = MenuBarRenderer.presentation(metrics: metrics, readings: readings,
                showAlertSlot: true, hasAlert: true, grouping: grouping, alerting: [metric])
            #expect(normal.image.size == alert.image.size)
            #expect(alert.highlightedValues.map(\.metric) == [metric])
            #expect(normal.highlightedValues.isEmpty)
            #expect(alert.image.isTemplate)
            if metrics.count > 1 {
                #expect(alert.highlightedValues.first?.frame.minY == ([Metric.cpu, .memory].contains(metric) ? 11 : 0))
            }
            if let pressure = alert.pressureFrame, let storage = alert.storageFrame {
                #expect(pressure.minX == storage.minX && pressure.minY > storage.maxY)
                #expect(pressure.size == storage.size)
            }
        }
    }
}

@Test @MainActor func accentLayerDrawsRedWarningAndDistinctStorageMarkers() throws {
    let readings: [Metric: MetricReading] = [.ssd: MetricReading(metric: .ssd, date: Date(),
        value: .storage(DiskCapacityReading(name: "SSD", total: 500e9, available: 10e9)))]
    var centerColors: [CapacityMenuBarValue: NSColor] = [:]
    for mode in CapacityMenuBarValue.allCases {
        let presentation = MenuBarRenderer.presentation(metrics: [.ssd], readings: readings,
            showAlertSlot: true, hasAlert: true, values: MenuBarValuePreferences(storage: mode), alerting: [.ssd])
        let preview = NSImage(size: presentation.image.size)
        preview.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: preview.size)).fill()
        MenuBarAccentOverlay.paint(presentation: presentation, pressure: nil, storageMode: mode)
        preview.unlockFocus()
        let data = try #require(preview.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var red = 0, blue = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.6 && color.greenComponent < 0.5 && color.blueComponent < 0.5 { red += 1 }
                if color.blueComponent > 0.6 && color.redComponent < 0.5 { blue += 1 }
            }
        }
        #expect(red > 0)
        if mode == .percentage || mode == .used {
            #expect(presentation.storageFrame == nil && blue == 0)
        } else {
            #expect(blue > 0)
            let frame = try #require(presentation.storageFrame)
            let x = Int(frame.midX / preview.size.width * Double(bitmap.pixelsWide))
            let y = bitmap.pixelsHigh - 1 - Int(frame.midY / preview.size.height * Double(bitmap.pixelsHigh))
            let center = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            // Remaining capacity and percentage share the same solid free-space marker.
            #expect(center.blueComponent > 0.6 && center.redComponent < 0.5)
            centerColors[mode] = center
        }
    }
    let available = try #require(centerColors[.available])
    #expect(centerColors[.availablePercentage] == available)
    #expect(MenuBarAccentOverlay(frame: .zero).hitTest(.zero) == nil)
}
