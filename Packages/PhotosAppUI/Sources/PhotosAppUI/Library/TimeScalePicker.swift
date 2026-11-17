import SwiftUI

/// Years | Months | All for the Library. On iOS 26.1 and later it sits in the tab bar's
/// bottom accessory; earlier, it floats as a glass capsule above the tab bar.
///
/// Like Photos, the segments sit straight on the glass (no track of their own), with a soft
/// capsule sliding behind the selected one. VoiceOver sees a standard segmented picker.
struct TimeScalePicker: View {
    @Bindable var ui: LibraryUIState
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TimeScale.allCases, id: \.self) { scale in
                segment(scale)
            }
        }
        .padding(4)
        .accessibilityRepresentation {
            Picker("Time Scale", selection: $ui.timeScale) {
                ForEach(TimeScale.allCases, id: \.self) { scale in
                    Text(scale.title).tag(scale)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ scale: TimeScale) -> some View {
        let isSelected = ui.timeScale == scale
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { ui.timeScale = scale }
        } label: {
            Text(scale.title)
                .font(.system(size: 17, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity)
                .contentShape(Capsule())
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// The picker on its own glass capsule, for where there's no bottom accessory.
struct FloatingTimeScalePicker: View {
    @Bindable var ui: LibraryUIState

    var body: some View {
        TimeScalePicker(ui: ui)
            .frame(width: 270, height: 48)
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
