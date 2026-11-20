import CoreHaptics
import UIKit

/// The feel of a press-and-hold, as Opal does it: a rumble that builds in
/// strength and sharpness for as long as the finger stays down, with small
/// rising ticks along the way, then one firm thump when it's done. Letting
/// go stops it at once. Phones without Core Haptics get a single impact at
/// the end.
@MainActor
final class HoldHaptics {
    static let shared = HoldHaptics()

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private func readyEngine() -> CHHapticEngine? {
        guard supported else { return nil }
        if let engine {
            // Auto shutdown stops it when idle: start it again, or the next
            // hold plays nothing.
            try? engine.start()
            return engine
        }
        guard let made = try? CHHapticEngine() else { return nil }
        made.isAutoShutdownEnabled = true
        made.resetHandler = { [weak self] in
            Task { @MainActor in try? self?.engine?.start() }
        }
        made.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.player = nil }
        }
        try? made.start()
        engine = made
        return made
    }

    /// The build-up, over `duration` seconds.
    func begin(duration: Double) {
        stop()
        // Felt the moment the finger lands, before the rumble builds.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let engine = readyEngine() else { return }
        var events = [
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
            ], relativeTime: 0, duration: duration),
        ]
        // Ticks at each quarter, each a little stronger: a ratchet winding up.
        for i in 1...3 {
            let at = duration * Double(i) / 4
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35 + 0.15 * Float(i)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4 + 0.1 * Float(i)),
            ], relativeTime: at))
        }
        // The rumble itself starts faint and soft and grows.
        let curves = [
            CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.3),
                .init(relativeTime: duration * 0.6, value: 0.55),
                .init(relativeTime: duration, value: 0.85),
            ], relativeTime: 0),
            CHHapticParameterCurve(parameterID: .hapticSharpnessControl, controlPoints: [
                .init(relativeTime: 0, value: -0.1),
                .init(relativeTime: duration, value: 0.35),
            ], relativeTime: 0),
        ]
        guard let pattern = try? CHHapticPattern(events: events, parameterCurves: curves),
              let made = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        player = made
        try? made.start(atTime: CHHapticTimeImmediate)
    }

    /// Let go early: silence.
    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    /// Done: the rumble stops and one firm thump lands.
    func finish() {
        stop()
        guard let engine = readyEngine() else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return
        }
        let thump = [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.75),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
            ], relativeTime: 0.02, duration: 0.12),
        ]
        if let pattern = try? CHHapticPattern(events: thump, parameters: []),
           let once = try? engine.makePlayer(with: pattern) {
            try? once.start(atTime: CHHapticTimeImmediate)
        }
    }
}
