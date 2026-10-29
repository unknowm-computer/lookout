import LookoutCore
import SwiftUI

struct TemperatureMenuPicker: View {
    @ObservedObject var settings: SettingsStore
    private var title: String { L10n.text("메뉴바 온도 표시") }
    var body: some View {
        Menu {
            Picker(title, selection: Binding(
                get: { settings.menuBarValues.temperature },
                set: { settings.setTemperatureMenuBarValue($0) }
            )) {
                ForEach(TemperatureMenuBarValue.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Text(settings.menuBarValues.temperature.title)
        }
        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.visible).controlSize(.mini)
        .font(.system(size: 10)).fixedSize()
        .disabled(!settings.configuration.enabled.contains(.cooling))
        .accessibilityLabel(title)
        .help(L10n.text("메뉴바에만 적용됩니다."))
    }
}
