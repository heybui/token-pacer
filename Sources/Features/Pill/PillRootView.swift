import SwiftUI

struct PillRootView: View {
    @Bindable var model: PillModel

    var body: some View {
        PillView(state: model.state)
            .onHover { inside in
                // Phase 0 proof: this only fires inside the shell rect, which means
                // PassthroughHostingView is letting the rest of the panel through.
                model.state = inside ? .hover : .collapsed
            }
    }
}
