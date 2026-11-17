import CloudCore
import Persistence
import SwiftUI

/// The signed-in app: the system tab bar (Library, Collections, and Search as its own
/// round tab), and in its place in the Library, the time scale row while browsing back in
/// time and select mode's footer.
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
                    .toolbar(ui.isSelecting || ui.showsTimeScaleRow ? .hidden : .automatic, for: .tabBar)
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

    /// The toast, and in place of the tab bar (hidden meanwhile) select mode's footer or
    /// the time scale row.
    private var libraryBottom: some View {
        VStack(spacing: 12) {
            toast
            if ui.isSelecting {
                SelectionFooter(ui: ui) { ui.shareRequested = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if ui.showsTimeScaleRow {
                TimeScaleRow(ui: ui)
                    .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, bottomGap)
        // The footer and the row sit where the tab bar was, over the home indicator's margin.
        .ignoresSafeArea(.container, edges: ui.isSelecting || ui.showsTimeScaleRow ? .bottom : [])
        .animation(.snappy, value: ui.isSelecting)
        .animation(.smooth(duration: 0.35), value: ui.showsTimeScaleRow)
    }

    /// The footer at the screen's edge; the row where iOS puts the minimized tab bar.
    private var bottomGap: CGFloat {
        if ui.isSelecting { return 0 }
        return ui.showsTimeScaleRow ? 27 : 12
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

/// iOS 26's tab bar. In the Library it stays full width (Library | Collections and Search)
/// and steps aside for the app's time scale row while browsing, so iOS never shows its
/// minimized bar there, nor a bottom accessory stacked above the full one. Collections
/// minimizes it on scrolling down, as usual.
private struct TabBarBehavior: ViewModifier {
    let ui: LibraryUIState

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .tabBarMinimizeBehavior(ui.section == .library ? .never : .onScrollDown)
                .tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }
}
