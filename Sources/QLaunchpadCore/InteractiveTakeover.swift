import Foundation

public enum InteractiveTakeover {
    /// Rebases an incoming gesture progress onto an interrupted presentation baseline progress.
    ///
    /// - Parameters:
    ///   - baseProgress: The presentation progress (0...1) at the moment of interruption.
    ///   - gestureProgress: The incoming gesture progress (0...1).
    ///   - isOpening: `true` if the gesture is opening (pinch in), `false` if closing (spread out).
    /// - Returns: The rebased presentation progress in the range 0...1.
    public static func rebasedProgress(
        baseProgress: CGFloat,
        gestureProgress: CGFloat,
        isOpening: Bool
    ) -> CGFloat {
        let clampedBase = min(1.0, max(0.0, baseProgress))
        let clampedGesture = min(1.0, max(0.0, gestureProgress))
        if isOpening {
            let p = clampedBase + clampedGesture * (1.0 - clampedBase)
            return min(1.0, max(0.0, p))
        } else {
            let p = clampedBase * (1.0 - clampedGesture)
            return min(1.0, max(0.0, p))
        }
    }
}
