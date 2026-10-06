/// Configure each item before registering the next one so AppKit lays out complete contents.
@MainActor enum MenuBarItemRegistration {
    static func update<Slot: Hashable, Item>(slots: [Slot], items: inout [Slot: Item],
                                            create: (Slot) -> Item, configure: (Slot, Item) -> Void) {
        for slot in slots.reversed() {
            let item: Item
            if let existing = items[slot] { item = existing }
            else {
                item = create(slot)
                items[slot] = item
            }
            configure(slot, item)
        }
    }
}
