import Foundation

/// Turns a flick of the thumb wheel into as few actions as it can, without ever
/// losing a change of direction.
///
/// The wheel reports one tick at a time and a single flick sends a burst of
/// them. Acting on each tick the moment it lands means one volume step and one
/// separate volume window animation per tick, which is where the wheel felt
/// jittery. Ticks going the same way are gathered up instead and handed over
/// once, so the volume window is drawn once for the whole flick.
///
/// The one thing gathering must never do is merge a flick one way into a flick
/// the other way: the moment the direction changes, or the hand moves to a
/// different mouse, whatever is waiting is handed over first.
final class WheelCoalescer {
    enum Direction: Hashable {
        case left
        case right
    }

    struct Batch: Equatable {
        let direction: Direction
        let deviceID: String
        /// How many times the bound action should fire. Never zero.
        let steps: Int
    }

    /// How many ticks one step is worth. 1 acts on every tick, which is what
    /// the wheel has always done.
    var sensitivity = 1

    /// Handed a whole flick at once.
    var onBatch: ((Batch) -> Void)?

    /// Asks for `flush()` to be called once the flick has had time to finish.
    /// Left unset in a check, where flushing is done by hand.
    var scheduleFlush: (() -> Void)?

    private var direction: Direction?
    private var deviceID: String?
    private var ticks = 0
    /// Ticks that were not enough for a whole step yet. Thrown away the moment
    /// the direction changes, so half a flick one way never adds to a flick the
    /// other way.
    private var carried = 0

    /// One tick off the wheel.
    func add(direction: Direction, deviceID: String) {
        if let waiting = self.direction, waiting != direction || self.deviceID != deviceID {
            flush()
            carried = 0
        }

        let isFirstOfFlick = ticks == 0
        self.direction = direction
        self.deviceID = deviceID
        ticks += 1

        if isFirstOfFlick {
            scheduleFlush?()
        }
    }

    /// Hands over whatever is waiting.
    func flush() {
        guard let direction, let deviceID, ticks > 0 else {
            return
        }

        let ticksPerStep = max(1, sensitivity)
        let total = carried + ticks
        let steps = total / ticksPerStep
        carried = total % ticksPerStep

        self.direction = nil
        self.deviceID = nil
        ticks = 0

        guard steps > 0 else {
            return
        }

        onBatch?(Batch(direction: direction, deviceID: deviceID, steps: steps))
    }

    /// Forgets everything waiting without acting on it.
    func reset() {
        direction = nil
        deviceID = nil
        ticks = 0
        carried = 0
    }
}
