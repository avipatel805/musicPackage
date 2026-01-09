import Foundation
import ARKit

/// Minimal ARKit bridge that converts ARFaceAnchor -> BlendInput (including calibrated headRoll)
final class FaceTrackingDriver: NSObject, ARSessionDelegate {

    private let session = ARSession()

    /// Called on every AR frame with the latest BlendInput.
    var onInput: ((BlendInput) -> Void)?

    // Roll calibration (baseline)
    private var rollBaseline: Float = 0
    private var hasBaseline = false

    // You previously had the “portrait vs landscape” issue — the fix is:
    // treat roll as RELATIVE to baseline (neutral) and keep everything compared to 0.
    func calibrateRollBaseline() {
        rollBaseline = lastRawRoll
        hasBaseline = true
    }

    private var lastRawRoll: Float = 0

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        let b = face.blendShapes

        let jawOpen = b[.jawOpen]?.floatValue ?? 0
        let eyeBlinkLeft = b[.eyeBlinkLeft]?.floatValue ?? 0
        let eyeBlinkRight = b[.eyeBlinkRight]?.floatValue ?? 0
        let mouthSmileL = b[.mouthSmileLeft]?.floatValue ?? 0
        let mouthSmileR = b[.mouthSmileRight]?.floatValue ?? 0
        let browInnerUp = b[.browInnerUp]?.floatValue ?? 0
        let cheekPuff = b[.cheekPuff]?.floatValue ?? 0
        let tongueOut = b[.tongueOut]?.floatValue ?? 0

        // Raw roll from transform (radians)
        let rawRoll = rollRadians(from: face.transform)
        lastRawRoll = rawRoll

        // Initialize baseline once we have stable data
        if !hasBaseline {
            rollBaseline = rawRoll
            hasBaseline = true
        }

        // Relative roll (0 = neutral)
        var relRoll = rawRoll - rollBaseline

        // Normalize to [-pi, pi] (prevents wraparound jumps)
        relRoll = wrapPi(relRoll)
        
        relRoll = -relRoll

        let input = BlendInput(
            jawOpen: jawOpen,
            eyeBlinkLeft: eyeBlinkLeft,
            eyeBlinkRight: eyeBlinkRight,
            mouthSmileL: mouthSmileL,
            mouthSmileR: mouthSmileR,
            browInnerUp: browInnerUp,
            cheekPuff: cheekPuff,
            tongueOut: tongueOut,
            headRoll: relRoll
        )

        onInput?(input)
    }

    // MARK: - Math

    private func rollRadians(from m: simd_float4x4) -> Float {
        // Z-rotation (roll). Works well when used RELATIVE to baseline.
        let r11 = m.columns.0.x
        let r21 = m.columns.0.y
        return atan2(r21, r11)
    }

    private func wrapPi(_ x: Float) -> Float {
        var v = x
        while v > .pi { v -= 2 * .pi }
        while v < -.pi { v += 2 * .pi }
        return v
    }
}

