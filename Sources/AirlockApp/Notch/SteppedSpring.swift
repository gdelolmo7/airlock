import CoreGraphics
import Foundation

/// A damped spring, stepped by hand every frame so a move can change target
/// mid-flight and keep its speed.
struct SteppedSpring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    /// Seconds to settle, roughly. Lower is snappier.
    var response: CGFloat
    /// 1 settles without overshoot; lower bounces.
    var damping: CGFloat

    init(_ value: CGFloat, response: CGFloat, damping: CGFloat) {
        self.value = value
        self.target = value
        self.response = response
        self.damping = damping
    }

    /// A spring with one of the five named motions' timing (`Motion`).
    init(_ value: CGFloat, motion: Motion) {
        self.init(value, response: CGFloat(motion.response), damping: CGFloat(motion.damping))
    }

    /// Takes on `motion`'s timing from here, keeping where it is and how fast
    /// it is going.
    mutating func use(_ motion: Motion) {
        response = CGFloat(motion.response)
        damping = CGFloat(motion.damping)
    }

    mutating func step(_ dt: CGFloat) {
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        var left = dt
        while left > 0 {
            let h = min(left, 1.0 / 240)
            velocity += (-stiffness * (value - target) - friction * velocity) * h
            value += velocity * h
            left -= h
        }
    }

    func isSettled(within tolerance: CGFloat) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance * 8
    }

    mutating func snap(to value: CGFloat) {
        self.value = value
        target = value
        velocity = 0
    }
}
