import Foundation

/// Normalised token counts. The two CLIs disagree about what nests inside what,
/// so every parser converts to this shape:
///
/// - `input` is always **uncached** input. Codex reports `input_tokens` inclusive
///   of `cached_input_tokens`, so its parser subtracts; Claude reports them apart.
/// - `reasoning` is a subset of `output` in both, kept for display only and never
///   counted again in the weighting.
struct TokenCounts: Equatable, Sendable, Codable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var reasoning = 0

    static let zero = TokenCounts()

    var total: Int { input + output + cacheWrite + cacheRead }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            cacheRead: a.cacheRead + b.cacheRead,
            reasoning: a.reasoning + b.reasoning
        )
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    func weighted(_ w: TokenWeights) -> Double {
        Double(input) * w.input
            + Double(output) * w.output
            + Double(cacheWrite) * w.cacheWrite
            + Double(cacheRead) * w.cacheRead
    }
}
