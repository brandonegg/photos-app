import SwiftUI

/// Years | Months | All for the Library, in the middle of `TimeScaleRow`.
///
/// Like Photos, the segments sit straight on the glass (no track of their own), with a soft
/// capsule behind the selected one. Pressing lifts it into a clear glass bubble that follows
/// the finger across the segments; letting go settles it on the nearest one and picks it (a
/// tap does the same in one go). The scale changes on release only, so the grid isn't rebuilt
/// mid-drag. VoiceOver sees a standard segmented picker.
struct TimeScalePicker: View {
    @Bindable var ui: LibraryUIState
    /// Where the bubble's centre is while a finger is down; nil at rest.
    @State private var dragX: CGFloat?

    private static let scales = TimeScale.allCases
    private static let inset: CGFloat = 4
    private static let settle = Animation.spring(response: 0.38, dampingFraction: 0.72)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = (size.width - Self.inset * 2) / CGFloat(Self.scales.count)
            let selected = Self.scales.firstIndex(of: ui.timeScale) ?? 0
            let x = dragX ?? center(of: selected, width: width)
            let highlighted = dragX.map { index(at: $0, width: width) } ?? selected
            let isLifted = dragX != nil

            ZStack {
                // At rest: the soft capsule behind the selected segment.
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: width, height: size.height - Self.inset * 2)
                    .position(x: x, y: size.height / 2)
                    .opacity(isLifted ? 0 : 1)

                HStack(spacing: 0) {
                    ForEach(Array(Self.scales.enumerated()), id: \.element) { offset, scale in
                        Text(scale.title)
                            .font(.system(size: 17, weight: offset == highlighted ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(Self.inset)

                // Pressed: the lifted glass bubble over the labels, a little larger than a segment.
                // Added and removed rather than faded: glass doesn't follow `.opacity`.
                if isLifted {
                    Color.clear
                        .frame(width: width + 10, height: size.height + 6)
                        .glassSurface(Capsule(), interactive: false, style: .clear)
                        .position(x: x, y: size.height / 2)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clamped = min(max(value.location.x, center(of: 0, width: width)),
                                          center(of: Self.scales.count - 1, width: width))
                        // The bubble lifts and moves to the finger, then tracks it.
                        withAnimation(dragX == nil ? .spring(response: 0.3, dampingFraction: 0.75) : .interactiveSpring) {
                            dragX = clamped
                        }
                    }
                    .onEnded { value in
                        let scale = Self.scales[index(at: value.location.x, width: width)]
                        withAnimation(Self.settle) {
                            ui.timeScale = scale
                            dragX = nil
                        }
                    }
            )
        }
        .accessibilityRepresentation {
            Picker("Time Scale", selection: $ui.timeScale) {
                ForEach(Self.scales, id: \.self) { scale in
                    Text(scale.title).tag(scale)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func center(of index: Int, width: CGFloat) -> CGFloat {
        Self.inset + width * (CGFloat(index) + 0.5)
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int {
        min(max(Int((x - Self.inset) / width), 0), Self.scales.count - 1)
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
                // As if from the tab bar's own Search tab: bring the tab bar back first. Picked
                // while it's hidden, Search opens with its field at the top of the screen
                // instead of in the tab bar, above the keyboard.
                ui.showTabBar()
                Task { @MainActor in
                    await Task.yield()
                    ui.section = .search
                }
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
