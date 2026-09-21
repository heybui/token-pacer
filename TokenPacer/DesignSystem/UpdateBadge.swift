import SwiftUI

/// A newer build is downloaded and waiting to be installed.
///
/// Blue, where the other two badges are amber: this is the only thing the pill
/// ever says that is neither a fault nor work in progress, and drawing it in a
/// warning colour would have people looking for what broke.
struct UpdateBadge: View {
    let version: String
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(Tokens.blue)
            // Product name, never a key.
            .help(Text(verbatim: "Token Pacer \(version)"))
            .accessibilityLabel(Text("Update available: \(version)"))
    }
}
