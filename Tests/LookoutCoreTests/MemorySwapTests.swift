import LookoutCore
import Testing

@Test func swapUsesItsOwnAllocationWithoutChangingRAMUsage() {
    let memory = MemoryReading(total: 32, app: 10, wired: 4, compressed: 2, swap: 3, swapTotal: 4)
    #expect(memory.swapPercent == 75)
    #expect(memory.swapAvailable == 1)
    #expect(memory.used == 16 && memory.available == 16 && memory.percent == 50)
    let expanded = MemoryReading(total: 32, app: 10, wired: 4, compressed: 2, swap: 3, swapTotal: 8)
    #expect(expanded.swapPercent == 37.5 && expanded.swapAvailable == 5)
}

@Test func swapDistinguishesZeroAllocationFromMissingOrInvalidMeasurements() {
    func reading(_ used: Double?, _ allocated: Double?) -> MemoryReading {
        MemoryReading(total: 32, app: 10, wired: 4, compressed: 2, swap: used, swapTotal: allocated)
    }
    #expect(reading(0, 0).swapPercent == 0 && reading(0, 0).swapAvailable == 0)
    #expect(reading(0, 4).swapPercent == 0 && reading(0, 4).swapAvailable == 4)
    #expect(reading(4, 4).swapPercent == 100 && reading(4, 4).swapAvailable == 0)
    #expect(reading(5, 4).swapPercent == 100 && reading(5, 4).swapAvailable == 0)
    for (used, allocated) in [(nil, 4.0), (3.0, nil), (1.0, 0.0), (-1.0, 4.0),
                              (1.0, -4.0), (Double.nan, 4.0), (1.0, Double.infinity)] as [(Double?, Double?)] {
        #expect(reading(used, allocated).swapPercent == nil)
        #expect(reading(used, allocated).swapAvailable == nil)
    }
}
