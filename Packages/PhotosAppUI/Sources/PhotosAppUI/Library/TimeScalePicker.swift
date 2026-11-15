import SwiftUI

/// Years | Months | All for the Library. On iOS 26.1 and later it sits in the tab bar's
/// bottom accessory; earlier, it floats as a glass capsule above the tab bar.
struct TimeScalePicker: View {
    @Bindable var ui: LibraryUIState

    var body: some View {
        Picker("Time Scale", selection: $ui.timeScale.animation(.spring(response: 0.38, dampingFraction: 0.72))) {
            ForEach(TimeScale.allCases, id: \.self) { scale in
                Text(scale.title).tag(scale)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// The picker on its own glass capsule, for where there's no bottom accessory.
struct FloatingTimeScalePicker: View {
    @Bindable var ui: LibraryUIState

    var body: some View {
        TimeScalePicker(ui: ui)
            .frame(width: 260)
            .padding(6)
            .glassSurface(Capsule())
    }
}

extension TimeScale {
    var title: LocalizedStringKey {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All"
        }
    }
}
