import SwiftUI

struct PillRootView: View {
    @Bindable var model: PillModel
    let store: UsageStore

    var body: some View {
        PillView(state: model.state, snapshot: store.snapshot)
            .onHover { inside in
                // Only fires inside the shell rect, which is how we know
                // PassthroughHostingView is letting the rest of the panel through.
                model.state = inside ? .hover : .collapsed
            }
    }
}
