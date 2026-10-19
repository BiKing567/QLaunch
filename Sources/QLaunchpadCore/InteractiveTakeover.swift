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

    /// Resolves the starting progress, target, and duration for finishing an interactive presentation.
    /// Guarantees that finishing towards 1.0 (commit open or cancel close) never resets
    /// the starting progress to 0.
    public static func finishParameters(
        currentProgress: CGFloat,
        target: CGFloat
    ) -> (from: CGFloat, to: CGFloat, duration: Double, isDismissing: Bool) {
        let clampedCurrent = min(1.0, max(0.0, currentProgress))
        let clampedTarget = min(1.0, max(0.0, target))
        let distance = abs(clampedTarget - clampedCurrent)
        let duration = max(0.12, min(0.30, Double(distance * 0.32)))
        let isDismissing = clampedTarget <= 0.001
        return (from: clampedCurrent, to: clampedTarget, duration: duration, isDismissing: isDismissing)
    }
}
