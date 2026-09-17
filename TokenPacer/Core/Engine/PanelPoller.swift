import Foundation

/// When a `/usage` run is worth what it costs.
///
/// It replaces the network-etiquette machinery, and it is a much smaller thing.
/// There is no undocumented endpoint to be a good guest at any more — the CLI
/// makes that call, with its own caching, on its own terms. What is left is local:
/// each run boots a whole Claude Code process for a few seconds, which is far too
/// much to spend on a machine that has not typed anything.
///
/// Activity gating is also the only honesty left about the figure. Nothing
/// extrapolates between runs now, so a frozen number is correct precisely when
/// the machine is idle — and idle is exactly when this refuses to run.
struct PanelPoller: Sendable, Codable {
    /// `pendingWeighted` is deliberately not archived: a cold start replays every
    /// retained event, so carrying it over would count the same tokens twice.
    enum CodingKeys: String, CodingKey { case lastRunAt, failures }

    /// Five minutes. The panel's own numbers are whole percentages, so a tighter
    /// cadence buys resolution the source does not have.
    var floor: TimeInterval = 300

    /// Re-read on this floor even with nothing in the logs.
    ///
    /// Quiet logs do not mean an idle account. The web app and Claude Design
    /// burn the same session limit and write no JSONL here at all, so the
    /// activity gate below never opened and the figure simply froze at whatever
    /// it was when the app launched — while the real one climbed.
    var idleFloor: TimeInterval = 1800

    /// The last reading moved with no local tokens to explain it: work is
    /// happening somewhere that writes no log here. Poll at the normal floor
    /// until a reading comes back flat, so an off-CLI session is tracked as
    /// closely as a CLI one and an idle machine still spawns almost nothing.
    var offLogActivity = false

    private(set) var lastRunAt: Date?
    /// Weighted tokens logged since the last run — the evidence that the number
    /// could have moved at all.
    private(set) var pendingWeighted: Double = 0
    private(set) var failures = 0

    var hasNewActivity: Bool { pendingWeighted > 0 }

    mutating func record(weighted: Double) {
        guard weighted > 0 else { return }
        pendingWeighted += weighted
    }

    /// The first run happens at launch regardless: with nothing to show, an idle
    /// machine would otherwise display nothing until someone typed.
    func shouldRun(at now: Date) -> Bool {
        guard let lastRunAt else { return true }
        let since = now.timeIntervalSince(lastRunAt)
        guard hasNewActivity || offLogActivity || since >= idleFloor else { return false }
        return since >= backoffFloor
    }

    /// Exponential, capped at an hour, so a CLI that is broken or mid-upgrade is
    /// not respawned every five minutes all day.
    private var backoffFloor: TimeInterval {
        guard failures > 0 else { return floor }
        return min(floor * pow(2, Double(min(failures, 5))), 3600)
    }

    mutating func ran(at now: Date) {
        lastRunAt = now
        pendingWeighted = 0
        failures = 0
    }

    mutating func failed(at now: Date) {
        lastRunAt = now
        failures += 1
    }
}
