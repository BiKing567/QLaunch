import Foundation

/// Mathematical decision model to distinguish trackpad multi-finger "pinch" from "swipe".
///
/// When four fingers swipe across the trackpad (e.g. to switch macOS desktops),
/// the center of gravity translates significantly while the fingers' spread remains
/// relatively constant until liftoff. Conversely, a true pinch gesture centers
/// around a stationary hand position while the spread changes significantly.
public struct TrackpadPinchIntent: Sendable {
    public enum Phase: Sendable, Equatable {
        case undecided
        case pinch
        case swipe
    }

    /// Ratio deviation from 1 before deciding it is a pinch.
    public static let deadZone = 0.04
    /// Center of gravity translation threshold relative to baseline before deciding it is a swipe.
    /// Real-world asymmetrical pinches exhibit travel of 0.08 - 0.18, whereas
    /// full desktop swipes exhibit travel >= 0.35.
    public static let swipeTravel = 0.22

    public private(set) var phase: Phase = .undecided

    public init() {}

    /// Update with a single gesture frame.
    /// - Parameters:
    ///   - ratio: Current spread divided by baseline spread.
    ///   - travel: Center translation distance divided by baseline spread.
    /// - Returns: True if confirmed as a pinch; false if undecided or detected as swipe.
    public mutating func update(ratio: Double, travel: Double) -> Bool {
        switch phase {
        case .pinch:
            return true
        case .swipe:
            return false
        case .undecided:
            // If hand translated significantly across the trackpad (full swipe travel), always classify as swipe
            if travel >= 0.35 {
                phase = .swipe
                return false
            }
            // If spread is visibly contracting with mild travel, prioritize pinch
            if ratio <= 0.88 {
                phase = .pinch
                return true
            }
            // If center translated while fingers stayed open/parallel, classify as swipe
            if travel > Self.swipeTravel {
                phase = .swipe
                return false
            }
            if abs(ratio - 1) > Self.deadZone {
                phase = .pinch
                return true
            }
            return false
        }
    }
}
