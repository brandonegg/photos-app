import CloudCore
import Persistence
import SwiftUI

/// The signed-in app: the system tab bar (Library, Collections, and Search as its own
/// round tab), the Library's Years | Months | All after scrolling, and select mode's footer
/// in place of the tab bar.
struct PhotosShell: View {
    let model: AppModel
    @State private var ui = LibraryUIState()

    init(model: AppModel) {
        self.model = model
        PhotosSettings.registerDefaults()
    }

    var body: some View {
        Group {
            if let session = model.session {
                tabs(session)
            } else if let error = model.sessionError {
                ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.phoneImages, model.session?.phoneImages)
        .task(id: model.session?.account.userID) {
            // First launch with the phone library: ask for Photos access (iOS shows its prompt once).
            if let session = model.session, session.photoAccess == .notDetermined {
                await session.requestPhotoAccess()
            }
        }
        .sheet(item: $ui.pendingSheet) { sheet in
            if let session = model.session {
                selectionSheet(sheet, session: session)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
            if let session = model.session {
                confirmationActions(session: session)
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: Tabs

    /// The tab selection. Tapping Library while it's showing goes to the newest photos, as in
    /// Photos, instead of the system's scroll to the top (the oldest photos here).
    private var sectionSelection: Binding<AppSection> {
        Binding {
            ui.section
        } set: { newValue in
            if newValue == .library, ui.section == .library, !ui.isSelecting {
                ui.scrollToNewestRequested = true
            }
            ui.section = newValue
        }
    }

    private func tabs(_ session: LibrarySession) -> some View {
        TabView(selection: sectionSelection) {
            Tab("Library", systemImage: "photo.on.rectangle.angled", value: AppSection.library) {
                LibraryScreen(model: model, session: session, ui: ui)
                    .overlay(alignment: .bottom) { libraryBottom }
                    .toolbar(ui.isSelecting ? .hidden : .automatic, for: .tabBar)
            }
            Tab("Collections", systemImage: "rectangle.stack.fill", value: AppSection.collections) {
                CollectionsScreen(model: model, session: session, ui: ui)
                    .overlay(alignment: .bottom) { toast.padding(.bottom, 12) }
            }
            Tab(value: AppSection.search, role: .search) {
                SearchScreen(session: session, ui: ui)
            }
        }
        .modifier(TabBarBehavior(ui: ui))
    }

    /// The toast, and select mode's footer (the tab bar hides) or, without a bottom
    /// accessory, the floating Years | Months | All.
    private var libraryBottom: some View {
        VStack(spacing: 12) {
            toast
            if ui.isSelecting {
                SelectionFooter(ui: ui) { ui.shareRequested = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if ui.barMode == .timeScale && !TabBarBehavior.hasAccessory {
                FloatingTimeScalePicker(ui: ui)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.bottom, ui.isSelecting ? 0 : 12)
        // The footer sits at the screen's edge, where the tab bar was.
        .ignoresSafeArea(.container, edges: ui.isSelecting ? .bottom : [])
        .animation(.snappy, value: ui.isSelecting)
        .animation(.smooth(duration: 0.35), value: ui.barMode)
    }

    private var toast: some View {
        VStack {
            if let toast = ui.toast {
                ToastView(message: toast)
            }
        }
        .animation(.snappy, value: ui.toast)
    }

    // MARK: Select mode sheets and confirmations

    @ViewBuilder
    private func selectionSheet(_ sheet: SelectionSheet, session: LibrarySession) -> some View {
        let ids = ui.selection
        let done: (String) -> Void = { message in
            ui.showToast(message)
            withAnimation(.snappy) { ui.endSelecting() }
        }
        switch sheet {
        case .showSelected:
            ShowSelectedSheet(session: session, ui: ui, items: session.timeline.items.filter { ui.isSelected($0.id) })
        case .addToAlbum(let shared):
            AlbumPickerView(session: session, shared: shared, assetIDs: ids, onDone: done)
        case .newAlbum(let shared):
            NewAlbumView(session: session, shared: shared, assetIDs: ids, onDone: done)
        case .adjustDate:
            if let first = ids.first, let details = session.detailsNow(for: first) {
                AdjustDateView(session: session, details: details, assetIDs: ids, onDone: done)
            }
        case .adjustLocation:
            if let first = ids.first, let details = session.detailsNow(for: first) {
                AdjustLocationView(session: session, details: details, assetIDs: ids, onDone: done)
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { ui.pendingConfirmation != nil }, set: { if !$0 { ui.pendingConfirmation = nil } })
    }

    private var confirmationTitle: String {
        let count = ui.selection.count
        switch ui.pendingConfirmation {
        case .delete: return count == 1 ? String(localized: "Delete 1 Item?") : String(localized: "Delete \(count) Items?")
        case .hide: return count == 1 ? String(localized: "Hide 1 Item?") : String(localized: "Hide \(count) Items?")
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch ui.pendingConfirmation {
        case .delete: model.session.map { String(localized: "These items will be deleted from Cloud, and from this iPhone where they are on it. You can recover them from Recently Deleted for \($0.trashRetentionDays) days.") } ?? ""
        case .hide: String(localized: "These items will be hidden, but can be found in the Hidden album in Collections › Utilities.")
        case nil: ""
        }
    }

    @ViewBuilder
    private func confirmationActions(session: LibrarySession) -> some View {
        let ids = ui.selection
        switch ui.pendingConfirmation {
        case .delete:
            Button(ids.count == 1 ? "Delete Item" : "Delete \(ids.count) Items", role: .destructive) {
                act(String(localized: "Moved to Recently Deleted")) { try await session.moveToTrash(assetIDs: ids) }
            }
        case .hide:
            Button(ids.count == 1 ? "Hide Item" : "Hide \(ids.count) Items") {
                act(String(localized: "Hidden")) { try await session.hide(assetIDs: ids) }
            }
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) {}
    }

    private func act(_ success: String, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                ui.showToast(success)
                withAnimation(.snappy) { ui.endSelecting() }
            } catch is CancellationError {
                // Declined in iOS's own prompt: nothing changed.
            } catch {
                ui.showToast((error as? CloudError)?.message ?? error.localizedDescription)
            }
        }
    }
}

/// iOS 26's tab bar: it shrinks while the Library or Collections scroll, and on iOS 26.1
/// and later the Library's Years | Months | All rides in its bottom accessory.
private struct TabBarBehavior: ViewModifier {
    @Bindable var ui: LibraryUIState

    static var hasAccessory: Bool {
        if #available(iOS 26.1, *) { true } else { false }
    }

    private var showsAccessory: Bool {
        ui.section == .library && ui.barMode == .timeScale && !ui.isSelecting && !ui.isTimeScaleDismissed
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabBarMinimizeBehavior(minimizeBehavior)
                .tabViewSearchActivation(.searchTabSelection)
                .tabViewBottomAccessory(isEnabled: showsAccessory) {
                    TimeScaleAccessory(ui: ui)
                }
        } else if #available(iOS 26.0, *) {
            content
                .tabBarMinimizeBehavior(minimizeBehavior)
                .tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }

    /// The Library starts at the newest photos at the bottom, so browsing back in time
    /// scrolls up; elsewhere, the usual scrolling down. Briefly `.never` on arriving at the
    /// newest photos, which expands a minimized bar (see `LibraryUIState.expandsTabBar`).
    @available(iOS 26.0, *)
    private var minimizeBehavior: TabBarMinimizeBehavior {
        guard ui.section == .library else { return .onScrollDown }
        return ui.expandsTabBar ? .never : .onScrollUp
    }
}

/// The bottom accessory: Years | Months | All, a little narrower beside the minimized tab bar.
/// Tapping the minimized tab bar expands it to Library | Collections alone, as in Photos: the
/// accessory steps aside until the grid is scrolled back again.
@available(iOS 26.0, *)
private struct TimeScaleAccessory: View {
    @Bindable var ui: LibraryUIState
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        TimeScalePicker(ui: ui)
            .padding(.horizontal, placement == .inline ? 0 : 4)
            .onChange(of: placement) { old, new in
                if old == .inline, new == .expanded { ui.tabBarExpanded() }
            }
    }
}
