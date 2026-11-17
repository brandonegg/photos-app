import SwiftUI

/// Years | Months | All for the Library, in the middle of `TimeScaleRow`.
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

/// The Library's bottom row while browsing back in time, in place of the tab bar: the
/// Library button, Years | Months | All, and Search, laid out like iOS's minimized tab bar.
/// Tapping Library brings back the full tab bar (Library | Collections), as in Photos.
struct TimeScaleRow: View {
    @Bindable var ui: LibraryUIState

    var body: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.smooth(duration: 0.35)) { ui.showTabBar() }
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassSurface(Circle())
            .accessibilityLabel("Library")
            .accessibilityHint("Shows the tab bar")

            TimeScalePicker(ui: ui)
                .frame(height: Self.height)
                .glassSurface(Capsule())

            Button {
                ui.section = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassSurface(Circle())
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 28)
    }

    /// The minimized tab bar's height.
    static let height: CGFloat = 48
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
