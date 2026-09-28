import Foundation

/// Port of the prototype's random series so the demo charts look exactly like the design.
public enum DemoSeries {
    /// Hourly token consumption (in thousands) per agent: `[hour][agent]`. Working hours 9–23 are busy.
    public static func hourlyTokens(agentCount: Int, hours: Int, seed: Int = 3) -> [[Int]] {
        var random = SeededRandom(seed: seed)
        return (0..<hours).map { hour in
            (0..<agentCount).map { agent in
                let dayHour = (hour + 14) % 24
                let weight = (dayHour >= 9 && dayHour <= 23) ? 1.0 : 0.15
                return Int((random.next() * weight * (agent == 0 ? 40 : 18)).rounded())
            }
        }
    }
}
