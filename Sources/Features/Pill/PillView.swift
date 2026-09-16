import SwiftUI

/// Phase 0: the shell only. Phase 2 fills in ring, odometer and countdown.
struct PillView: View {
    let state: PillState

    var body: some View {
        VStack(spacing: 0) {
            shell
            Spacer(minLength: 0)
        }
        .frame(width: PillState.hostSize.width, height: PillState.hostSize.height)
    }

    private var shell: some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: state.cornerRadius,
            bottomTrailingRadius: state.cornerRadius
        )
        .fill(.black)
        .overlay {
            UnevenRoundedRectangle(
                bottomLeadingRadius: state.cornerRadius,
                bottomTrailingRadius: state.cornerRadius
            )
            .strokeBorder(state == .collapsed ? Tokens.shellRingIdle : Tokens.shellRingOpen, lineWidth: 1)
        }
        .overlay {
            if state != .dormant {
                Text("burn tracker")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: state.size.width, height: state.size.height)
        .opacity(state.opacity)
        .shadow(color: .black.opacity(0.66), radius: 31, y: 22)
        .animation(Tokens.spring, value: state)
    }
}
