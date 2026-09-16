import Foundation

/// Cost-equivalent weighting, so a cache read doesn't count like fresh output.
///
/// Calibration knob, not a constant: these ratios track published pricing and
/// drift with it. If Claude's inferred percentage diverges from Codex's
/// authoritative one under comparable load, suspect these before the engine.
struct TokenWeights: Equatable, Sendable, Codable {
    var input: Double = 1.0
    var output: Double = 5.0
    var cacheWrite: Double = 1.25
    var cacheRead: Double = 0.1

    static let `default` = TokenWeights()
}
