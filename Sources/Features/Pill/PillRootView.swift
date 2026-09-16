import SwiftUI

struct PillRootView: View {
    let model: PillModel
    let store: UsageStore

    var body: some View {
        PillView(
            state: model.state,
            snapshot: store.snapshot,
            attention: store.errors[store.activeSource],
            bySource: store.bySource,
            onTogglePinned: { model.togglePinned() },
            onClose: { model.setPinned(false) }
        )
            .onHover { inside in
                // Only fires inside the shell rect, which is how we know
                // PassthroughHostingView is letting the rest of the panel through.
                model.setPointerInside(inside)
            }
            .onChange(of: store.snapshot) { _, snapshot in
                model.update(snapshot: snapshot)
            }
    }
}
