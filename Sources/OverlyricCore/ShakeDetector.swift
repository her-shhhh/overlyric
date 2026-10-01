import Foundation

/// Recognises a quick side-to-side shake while dragging: `requiredSwings` horizontal swings of at least
/// `minSwing` points, each reversing direction, all within `window` seconds.
public struct ShakeDetector {
    public static let minSwing: Double = 25
    public static let requiredSwings = 4
    public static let window: TimeInterval = 0.9
    /// How far the pointer must come back from the furthest point before it counts as a reversal.
    static let retreat: Double = 8

    private var pivot: Double?          // where the current swing started
    private var extreme: Double = 0     // furthest point of the current swing
    private var direction: Double = 0   // +1 right, -1 left, 0 unknown
    private var swings: [TimeInterval] = []

    public init() {}

    /// Feeds one pointer x position; returns true when a shake has just been completed.
    public mutating func feed(x: Double, time: TimeInterval) -> Bool {
        guard let p = pivot else { pivot = x; extreme = x; return false }
        if direction == 0 {
            if abs(x - p) >= 3 { direction = x > p ? 1 : -1; extreme = x }
            return false
        }
        if (direction > 0 && x >= extreme) || (direction < 0 && x <= extreme) {
            extreme = x
            return false
        }
        guard abs(extreme - x) >= Self.retreat else { return false }
        // Reversal: the swing that just ended counts if it was big enough.
        if abs(extreme - p) >= Self.minSwing { swings.append(time) }
        pivot = extreme
        direction = -direction
        extreme = x
        swings.removeAll { time - $0 > Self.window }
        if swings.count >= Self.requiredSwings {
            swings.removeAll()
            return true
        }
        return false
    }
}
