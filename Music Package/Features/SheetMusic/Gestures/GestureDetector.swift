import Foundation

// MARK: - Gesture choice for settings UI
enum PageTurnGesture: String, CaseIterable, Identifiable, Codable {
    case smile
    case jawOpen = "jaw open"
    case blink
    case browRaise = "brow raise"
    case cheekPuff = "cheek puff"
    case tongueOut = "tongue out"
    case headTiltLeft = "head tilt left"
    case headTiltRight = "head tilt right"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smile: return "Smile"
        case .jawOpen: return "Jaw Open"
        case .blink: return "Blink"
        case .browRaise: return "Brow Raise"
        case .cheekPuff: return "Cheek Puff"
        case .tongueOut: return "Tongue Out"
        case .headTiltLeft: return "Head Tilt Left"
        case .headTiltRight: return "Head Tilt Right"
        }
    }

    var isTilt: Bool { self == .headTiltLeft || self == .headTiltRight }
}

// MARK: - Inputs / outputs
struct BlendInput {
    let jawOpen: Float
    let eyeBlinkLeft: Float
    let eyeBlinkRight: Float
    let mouthSmileL: Float
    let mouthSmileR: Float
    let browInnerUp: Float
    let cheekPuff: Float
    let tongueOut: Float
    let headRoll: Float   // radians, signed relative to screen baseline (0 = neutral)
}

struct GestureOutput {
    let activeGestures: [String]
}

/// Detection engine.
/// Now supports:
/// - per-gesture "is active" queries
/// - confidence (0...100) to make detection stricter/looser
final class GestureDetector {

    // Exponential moving average smoothing
    private let alpha: Float = 0.35
    private var sJaw: Float = 0
    private var sBlinkL: Float = 0
    private var sBlinkR: Float = 0
    private var sSmile: Float = 0
    private var sBrow: Float = 0
    private var sCheek: Float = 0
    private var sTongue: Float = 0
    private var sRoll: Float = 0

    // Hysteresis states
    private var isSmiling = false
    private var isMouthOpen = false
    private var isBlinking = false
    private var isBrowRaised = false
    private var isTiltLeft = false
    private var isTiltRight = false

    /// Main update: returns list for debug/logging compatibility
    func update(with i: BlendInput, confidence: Int) -> GestureOutput {
        sJaw    = ema(sJaw, i.jawOpen)
        sBlinkL = ema(sBlinkL, i.eyeBlinkLeft)
        sBlinkR = ema(sBlinkR, i.eyeBlinkRight)
        sSmile  = ema(sSmile, (i.mouthSmileL + i.mouthSmileR) / 2)
        sBrow   = ema(sBrow, i.browInnerUp)
        sCheek  = ema(sCheek, i.cheekPuff)
        sTongue = ema(sTongue, i.tongueOut)
        sRoll   = ema(sRoll, i.headRoll)

        // Map confidence (0...100) -> stricter thresholds.
        // Low confidence => easier to trigger; high confidence => harder to trigger.
        let c = clamp01(Float(confidence) / 100)

        // Blendshape thresholds (0..1). We lerp between easy and strict.
        let smileOn  = lerp(0.45, 0.70, c)
        let smileOff = lerp(0.30, 0.55, c)

        let jawOn    = lerp(0.40, 0.65, c)
        let jawOff   = lerp(0.28, 0.50, c)

        let blinkOn  = lerp(0.45, 0.75, c)
        let blinkOff = lerp(0.25, 0.55, c)

        let browOn   = lerp(0.40, 0.65, c)
        let browOff  = lerp(0.25, 0.50, c)

        // Tilt thresholds (radians). Lerp between ~10° and ~25° for "on".
        // Off threshold is lower to provide hysteresis.
        let tiltOn   = lerp(0.18, 0.44, c)   // 10° -> 25°
        let tiltOff  = lerp(0.10, 0.30, c)   // 6°  -> 17°

        toggle(&isSmiling,    on: sSmile > smileOn,   off: sSmile < smileOff)
        toggle(&isMouthOpen,  on: sJaw   > jawOn,     off: sJaw   < jawOff)

        // Blink: treat as either eye above threshold
        let blinkValue = max(sBlinkL, sBlinkR)
        toggle(&isBlinking,   on: blinkValue > blinkOn, off: blinkValue < blinkOff)

        toggle(&isBrowRaised, on: sBrow  > browOn,     off: sBrow  < browOff)

        toggle(&isTiltLeft,   on: sRoll < -tiltOn,     off: sRoll > -tiltOff)
        toggle(&isTiltRight,  on: sRoll >  tiltOn,     off: sRoll <  tiltOff)

        // Prevent both at once
        if isTiltLeft { isTiltRight = false }
        if isTiltRight { isTiltLeft = false }

        var active = [String]()
        if isSmiling { active.append(PageTurnGesture.smile.rawValue) }
        if isMouthOpen { active.append(PageTurnGesture.jawOpen.rawValue) }
        if isBlinking { active.append(PageTurnGesture.blink.rawValue) }
        if isBrowRaised { active.append(PageTurnGesture.browRaise.rawValue) }
        if sCheek > lerp(0.45, 0.70, c) { active.append(PageTurnGesture.cheekPuff.rawValue) }
        if sTongue > lerp(0.45, 0.70, c) { active.append(PageTurnGesture.tongueOut.rawValue) }
        if isTiltLeft { active.append(PageTurnGesture.headTiltLeft.rawValue) }
        if isTiltRight { active.append(PageTurnGesture.headTiltRight.rawValue) }

        return GestureOutput(activeGestures: active)
    }

    /// Query whether a particular gesture is active *after the last update*.
    func isActive(_ g: PageTurnGesture) -> Bool {
        switch g {
        case .smile: return isSmiling
        case .jawOpen: return isMouthOpen
        case .blink: return isBlinking
        case .browRaise: return isBrowRaised
        case .cheekPuff: return sCheek > 0.60
        case .tongueOut: return sTongue > 0.60
        case .headTiltLeft: return isTiltLeft
        case .headTiltRight: return isTiltRight
        }
    }

    private func ema(_ s: Float, _ x: Float) -> Float { alpha * x + (1 - alpha) * s }
    private func toggle(_ state: inout Bool, on: Bool, off: Bool) { if on { state = true } else if off { state = false } }

    private func clamp01(_ x: Float) -> Float { max(0, min(1, x)) }
    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}

