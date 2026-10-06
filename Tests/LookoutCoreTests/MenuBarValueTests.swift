import Foundation
import LookoutCore
import Testing

@Test func capacityMenuValuesHaveRecommendedDefaultsAndRestoreIndependently() throws {
    let defaults = try JSONDecoder().decode(MenuBarValuePreferences.self, from: Data("{}".utf8))
    #expect(defaults.memory == .percentage && defaults.storage == .available)
    let invalid = try JSONDecoder().decode(MenuBarValuePreferences.self, from: Data("{\"memory\":\"future\",\"storage\":\"used\"}".utf8))
    #expect(invalid.memory == .percentage && invalid.storage == .used)
    let choices = MenuBarValuePreferences(memory: .available, storage: .percentage)
    #expect(try JSONDecoder().decode(MenuBarValuePreferences.self, from: JSONEncoder().encode(choices)) == choices)
}

@Test func capacityMenuValuesUseRAMBinaryAndSSDDecimalCapacity() {
    let gib = 1_073_741_824.0
    let ram = ReadingValue.memory(MemoryReading(total: 32 * gib, app: 10 * gib, wired: 4 * gib, compressed: 10 * gib, swap: nil))
    let ssd = ReadingValue.storage(DiskCapacityReading(name: "SSD", total: 500e9, available: 125e9))
    let defaults = MenuBarValuePreferences()
    #expect(defaults.text(for: .memory, value: ram) == "75%")
    #expect(defaults.text(for: .ssd, value: ssd) == "125 GB")
    #expect(MenuBarValuePreferences(memory: .available).text(for: .memory, value: ram) == "8.0 GiB")
    #expect(MenuBarValuePreferences(memory: .used, storage: .used).text(for: .ssd, value: ssd) == "375 GB")
    #expect(MenuBarValuePreferences(memory: .used).text(for: .memory, value: ram) == "24.0 GiB")
    #expect(MenuBarValuePreferences(storage: .percentage).text(for: .ssd, value: ssd) == "75%")
    #expect(MenuBarValuePreferences(memory: .availablePercentage).text(for: .memory, value: ram) == "25%")
    #expect(MenuBarValuePreferences(storage: .availablePercentage).text(for: .ssd, value: ssd) == "25%")
    #expect(defaults.text(for: .ssd, value: nil) == "—")
    #expect(defaults.text(for: .memory, value: ssd) == "—")
}

@Test func capacityMenuValuesPreserveLegacyChoicesAndBothPercentageMeanings() throws {
    let modes: [(CapacityMenuBarValue, CapacityMenuBarValue, Bool)] = [
        (.percentage, .used, true), (.used, .used, false),
        (.available, .available, false), (.availablePercentage, .available, true)
    ]
    for (mode, capacity, percentage) in modes {
        let restored = try JSONDecoder().decode(MenuBarValuePreferences.self,
            from: Data("{\"memory\":\"\(mode.rawValue)\",\"storage\":\"\(mode.rawValue)\"}".utf8))
        #expect(restored.memory.capacity == capacity && restored.memory.isPercentage == percentage)
        #expect(CapacityMenuBarValue(capacity: capacity, percentage: percentage) == mode)
        #expect(try JSONDecoder().decode(MenuBarValuePreferences.self,
            from: JSONEncoder().encode(restored)) == restored)
    }
}

@Test func remainingMenuPercentageHandlesEmptyFullAndUnavailableTotals() {
    let values = MenuBarValuePreferences(memory: .availablePercentage, storage: .availablePercentage)
    for (available, expected) in [(0.0, "0%"), (100.0, "100%")] {
        let ram = MemoryReading(total: 100, app: 100 - available, wired: 0, compressed: 0, swap: nil)
        let ssd = DiskCapacityReading(name: "SSD", total: 100, available: available)
        #expect(values.text(for: .memory, value: .memory(ram)) == expected)
        #expect(values.text(for: .ssd, value: .storage(ssd)) == expected)
    }
    for total in [0.0, -1, Double.infinity, Double.nan] {
        let ram = MemoryReading(total: total, app: 0, wired: 0, compressed: 0, swap: nil)
        let ssd = DiskCapacityReading(name: "SSD", total: total, available: 0)
        #expect(values.text(for: .memory, value: .memory(ram)) == "—")
        #expect(values.text(for: .ssd, value: .storage(ssd)) == "—")
    }
}

@Test func storageMenuBarTruncatesAtDisplayThresholdsWithoutChangingDetailFormat() {
    let cases: [(Double, String)] = [
        (111.9e9, "111 GB"), (100e9, "100 GB"), (99.999e9, "99.9 GB"),
        (63.89e9, "63.8 GB"), (0.85e9, "850 MB"), (999_999_999, "999 MB"),
        (1e9, "1.0 GB"), (1.25e12, "1.2 TB"), (100.9e12, "100 TB"),
        (999_999, "999 KB"), (63_890, "63.8 KB"), (999, "999 B"), (0, "0 B")
    ]
    for (bytes, expected) in cases { #expect(ValueFormat.menuBarStorage(bytes) == expected) }
    #expect(ValueFormat.storage(111.9e9) == "111.9 GB")
    #expect(ValueFormat.menuBarStorage(.nan) == "—")
    #expect(ValueFormat.menuBarStorage(-1) == "—")
}

@Test func pressureUsesKernelDispatchFlagsAndDoesNotInferFromUtilization() {
    #expect(MemoryPressure(rawValue: 1) == .normal)
    #expect(MemoryPressure(rawValue: 2) == .warning)
    #expect(MemoryPressure(rawValue: 4) == .critical)
    #expect(MemoryPressure(rawValue: 0) == nil)
    #expect(MemoryPressure(rawValue: 3) == nil)
    let memory = MemoryReading(total: 100, app: 95, wired: 3, compressed: 1, swap: 40, pressure: .normal)
    #expect(memory.percent == 99 && memory.pressure == .normal && memory.available == 1)
    #expect(MemoryReading(total: 100, app: 110, wired: 0, compressed: 0, swap: nil).available == 0)
}
