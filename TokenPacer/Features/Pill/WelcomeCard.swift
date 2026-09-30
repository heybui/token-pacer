import SwiftUI

/// What a first launch opens on: which providers the app found, what each one
/// has reported, and what to do about the ones that cannot be read.
///
/// Every other state assumes the notch is already known to be where the app
/// lives, and the quiet one hides it outright — so a fresh install used to look
/// like an app that had not started. This stays until it is answered, and comes
/// back on its own when every tracked provider is failing, because then the
/// pill has nothing to show and this is the only surface that says why.
struct WelcomeCard: View {
    struct Row: Identifiable, Equatable {
        let source: SourceID
        let status: Status
        var id: SourceID { source }
    }

    enum Status: Equatable {
        case notInstalled
        case reading
        case reported(percent: Double, windowMinutes: Int?)
        /// The kind when the store knows it, and the sentence it showed.
        case failed(PanelError?, message: String)

        /// Nothing this provider can show until somebody does something.
        var isStuck: Bool {
            switch self {
            case .notInstalled, .failed: true
            case .reading, .reported: false
            }
        }
    }

    let rows: [Row]
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    @Environment(\.tone) private var toneScale

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // The product's name, interpolated: it is never a key of its own.
            Text("\(AppInfo.name) is watching your AI usage")
                .font(Typography.sans(13, .semibold))
                .foregroundStyle(.white)

            ForEach(rows) { row in
                WelcomeRow(row: row, tone: tone(row.status))
            }

            // Its own line: beside the two buttons it was cut off halfway, and
            // it is the one sentence the card exists to leave behind.
            Text("Hover the notch any time · double-click it for the full panel")
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 8) {
                Spacer(minLength: 8)
                WelcomeButton(title: "Preferences", tint: .white.opacity(0.55), action: onOpenSettings)
                WelcomeButton(title: "Got it", tint: Tokens.green, action: onDismiss)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func tone(_ status: Status) -> Color {
        switch status {
        case .reported(let percent, _): toneScale(percent)
        case .failed: Tokens.amber
        case .notInstalled, .reading: .white.opacity(0.4)
        }
    }
}

private struct WelcomeRow: View {
    let row: WelcomeCard.Row
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tone)
                    .frame(width: 12)
                Text(verbatim: row.source.wordmark)
                    .font(Typography.mono(9.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                Text(verbatim: status)
                    .font(Typography.sans(11.5))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let hint {
                Text(verbatim: hint)
                    .font(Typography.sans(10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 20)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private var symbol: String {
        switch row.status {
        case .reported: "checkmark.circle.fill"
        case .reading: "ellipsis.circle"
        case .failed, .notInstalled: "exclamationmark.circle.fill"
        }
    }

    private var status: String {
        switch row.status {
        case .notInstalled: String(localized: "not installed")
        case .reading: String(localized: "reading usage…")
        case .reported(let percent, let minutes):
            String(
                localized: "\(Format.percent(percent)) of this \(Format.windowName(minutes))",
                comment: "Welcome row. First value is a percentage, second names a window."
            )
        case .failed(_, let message): message
        }
    }

    /// The one thing to do, where there is one. The command is the binary's
    /// own name, typed as it is typed.
    private var hint: String? {
        let name = row.source.displayName
        let command = row.source.command
        switch row.status {
        case .notInstalled, .failed(.cliNotFound?, _):
            return String(localized: "Install the \(name) CLI to track it")
        case .failed(.notSignedIn?, _):
            return String(localized: "Run \(command) in a terminal and sign in")
        case .failed(.noTrustedDirectory?, _):
            return String(localized: "Run \(command) in a project folder and trust it")
        case .failed:
            return String(localized: "Trying again shortly")
        case .reading, .reported:
            return nil
        }
    }
}

private struct WelcomeButton: View {
    let title: LocalizedStringKey
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.sans(11.5, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverChip()
    }
}

private extension SourceID {
    /// What is typed to start it.
    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .copilot: "copilot"
        }
    }
}
