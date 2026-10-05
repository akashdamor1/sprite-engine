import SwiftUI
import AppKit
import ImageIO
import QuartzCore

// MARK: - Sprite bank

/// Loads the baked VN sprite layers (Models/sprites → app Resources/sprites) once, fully decoded.
///
/// v4 denser mouths (canvas 1024×1024, crops positioned by `sprite_manifest.json` rects):
///   head_{left3|left2|left1|center|right1|right2|right3}.png         opaque head bases (7)
///   eyes_{H}_{center|left1-3|right1-3|up1-3|down1-3|blink1-3|closed}.png  eye-band crops (7×17 = 119)
///   mouth_{H}_{o0…o15}.png                                            mouth crops, 16 openness tiers (7×16 = 112)
final class SpriteBank {
    struct Sprite { let image: CGImage; let rect: CGRect }

    static let shared = SpriteBank()
    private(set) var sprites: [String: Sprite] = [:]
    private(set) var canvas: CGFloat = 1024
    private(set) var sourceNote = "no sprites"

    private init() {
        var dir: URL?
        if let res = Bundle.main.resourceURL?.appendingPathComponent("sprites"),
           FileManager.default.fileExists(atPath: res.path) {
            dir = res
            sourceNote = "bundle"
        } else {
            let dev = URL(fileURLWithPath: ("~/GrokAvatar/Models/sprites" as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: dev.path) {
                dir = dev
                sourceNote = "Models/sprites"
            }
        }
        guard let dir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }

        var rects: [String: [Double]] = [:]
        if let data = try? Data(contentsOf: dir.appendingPathComponent("sprite_manifest.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let c = obj["canvas"] as? Double { canvas = CGFloat(c) }
            rects = (obj["rects"] as? [String: [Double]]) ?? [:]
        }

        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        for url in files where url.pathExtension.lowercased() == "png" {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, opts) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let r: CGRect
            if let a = rects[name], a.count == 4 {
                r = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
            } else {
                r = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
            }
            sprites[name] = Sprite(image: cg, rect: r)
        }
        sourceNote += " · \(sprites.count) frames"
    }

    func sprite(_ name: String) -> Sprite? { sprites[name] }
}


// MARK: - Viewer / window parallax

/// Screen-space offset so eyes look toward the user (camera ≈ top-center of the display)
/// when the floating window is dragged around. Returns yaw/pitch in −1…1 (same space as FaceTracker).
enum ViewerParallax {
    /// Gain: full travel from screen center to edge ≈ this fraction of max look.
    private static let gainX: Float = 0.82
    private static let gainY: Float = 0.70

    static func offset(for window: NSWindow?) -> (yaw: Float, pitch: Float) {
        guard let window else { return (0, 0) }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return (0, 0) }
        let sf = screen.frame
        // Built-in MacBook camera sits at the top-center of the display bezel.
        let camX = sf.midX
        let camY = sf.maxY
        // Positive deltaX → camera is to the right of the window → look right (positive yaw).
        let dx = Float(camX - frame.midX)
        let dy = Float(camY - frame.midY)
        let halfW = Float(max(sf.width * 0.5, 1))
        let halfH = Float(max(sf.height * 0.5, 1))
        let yaw = max(-1, min(1, (dx / halfW) * gainX))
        let pitch = max(-1, min(1, (dy / halfH) * gainY))
        return (yaw, pitch)
    }

    /// Prefer the visible GrokAvatar window (floating avatar), else key window.
    static func avatarWindow() -> NSWindow? {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 300 && $0.frame.height >= 300 }) {
            return w
        }
        return NSApp.keyWindow ?? NSApp.windows.first
    }
}

// MARK: - Frame selection (inputs → frame names, with hysteresis + short crossfade)

final class SpriteDriver: ObservableObject {
    static let heads = ["left3", "left2", "left1", "center", "right1", "right2", "right3"]   // yaw level -3…+3
    static let eyesX = ["left3", "left2", "left1", "center", "right1", "right2", "right3"]   // look level -3…+3
    static let eyesY = ["down3", "down2", "down1", "center", "up1", "up2", "up3"]            // pitch level -3…+3
    static let blinks = ["open", "blink1", "blink2", "blink3", "closed"]                       // lid 0 / 22 / 45 / 70 / 100 %
    static let mouths = ["o0", "o1", "o2", "o3", "o4", "o5", "o6", "o7", "o8", "o9", "o10", "o11", "o12", "o13", "o14", "o15"]  // jaw tier 0…15
    static let centerIdx = 3

    // Thresholds (boundaries between neighbouring levels) + hysteresis margin
    private static let yawBounds: [Float] = [-0.62, -0.38, -0.15, 0.15, 0.38, 0.62];   private static let yawHys: Float = 0.03
    private static let lookBounds: [Float] = [-0.40, -0.24, -0.09, 0.09, 0.24, 0.40];  private static let lookHys: Float = 0.025
    private static let pitchBounds: [Float] = [-0.45, -0.28, -0.12, 0.12, 0.28, 0.45]; private static let pitchHys: Float = 0.03
    private static let blinkBounds: [Float] = [0.15, 0.38, 0.60, 0.82];                private static let blinkHys: Float = 0.03
    // Quiet → early o1–o4; mid o5–o10; loud o11–o15. Finer steps + smaller hys for smoother lip motion.
    // High first tier so residual jaw never flaps o0; jawClosedMax still hard-forces o0 when idle.
    private static let jawBounds: [Float] = [
        0.10, 0.15, 0.20, 0.25, 0.30, 0.36, 0.42, 0.48,
        0.54, 0.60, 0.66, 0.72, 0.78, 0.85, 0.92
    ]
    private static let jawHys: Float = 0.015
    /// Absolute closed-mouth clamp — below this SpriteDriver forces o0 regardless of hysteresis.
    private static let jawClosedMax: Float = 0.06

    @Published private(set) var head = "center"
    @Published private(set) var eyes = "center"
    @Published private(set) var mouth = "o0"
    @Published private(set) var prevHead = "center"
    @Published private(set) var prevEyes = "center"
    @Published private(set) var prevMouth = "o0"
    @Published private(set) var blend: Double = 1      // 0 → show prev frame, 1 → current frame
    @Published private(set) var glow: Double = 0

    // Liveliness: continuous sub-sprite head motion applied to the whole layer stack
    // (head + eyes + mouth move together, so the mouth never ghosts / chatters).
    @Published private(set) var swayRoll: Double = 0   // degrees (head tilt)
    @Published private(set) var swayDX: Double = 0     // fraction of face side
    @Published private(set) var swayDY: Double = 0     // fraction of face side (+ = down / nod)
    @Published private(set) var mood = "idle"          // idle · pause · talk · think (debug label)

    private weak var engine: LipSyncEngine?
    private weak var tracker: FaceTracker?
    private var timer: Timer?

    // quantizer state (indices into the arrays above)
    private var yawIdx = 3, lookIdx = 3, pitchIdx = 3, blinkIdx = 0, jawIdx = 0
    private var fadeStart: CFTimeInterval = 0
    private var fadeDur: CFTimeInterval = 0.1

    // idle glances when no face is tracked AND window is near screen/camera (VN-style "alive" eyes)
    private var nextGlanceAt = CACurrentMediaTime() + 2.5
    private var glanceUntil: CFTimeInterval = 0
    private var glance = (x: 3, y: 3)

    // Smoothed window→viewer parallax (keeps eyes on the user while dragging the window)
    private var smoothWinYaw: Float = 0
    private var smoothWinPitch: Float = 0
    private let winEma: Float = 0.28

    // MARK: Liveliness state
    private var lastTick = CACurrentMediaTime()
    /// Audio counts as "active" (listening / speaking) above LipSyncEngine.speakGate or once unlocked.
    private static let activeGate: Float = 0.022

    // 1) Natural blink — own human rhythm, blended (max) with any external blink channel.
    private static let blinkClose: Double = 0.075   // lid down (ease-in)
    private static let blinkHold: Double = 0.045    // fully closed
    private static let blinkOpen: Double = 0.17     // lid up (slower, ease-out)
    private var nextBlinkAt = CACurrentMediaTime() + Double.random(in: 1.5...3.5)
    private var blinkStart: CFTimeInterval = -1     // < 0 → not blinking
    private var blinkPeak: Float = 1                // < 1 → partial blink
    private var blinkIsDouble = false
    private var lastOwnBlinkEnd: CFTimeInterval = -10
    private var extBlinkActive = false
    private var extBlinkAccepted = false

    // 2/3) Head sway — phase accumulators so rate changes never jump.
    private var swayPh1 = Double.random(in: 0..<(2 * .pi))
    private var swayPh2 = Double.random(in: 0..<(2 * .pi))
    private var swayPh3 = Double.random(in: 0..<(2 * .pi))
    private var bobPh = Double.random(in: 0..<(2 * .pi))
    private var swayAmp: Float = 0.32
    private var swayRate: Float = 0.4
    private var jawSmooth: Float = 0
    private var lastActiveAt = CACurrentMediaTime() - 10
    private var wasActive = false

    // 4) Thinking expression on silence → speech onset.
    private static let thinkQuietMin: CFTimeInterval = 0.9
    private var thinkStart: CFTimeInterval = -10
    private var thinkUntil: CFTimeInterval = 0
    private var thinkEyes = "up2"
    private var thinkHeadBias: Float = 0
    private var thinkLift: Float = 0
    private var thinkCooldownUntil: CFTimeInterval = 0

    func attach(engine: LipSyncEngine, tracker: FaceTracker) {
        self.engine = engine
        self.tracker = tracker
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        timer?.invalidate()
        timer = nil
    }

    var headFrame: String { "head_\(head)" }
    var eyesFrame: String { "eyes_\(head)_\(eyes)" }
    var mouthFrame: String { "mouth_\(head)_\(mouth)" }
    var prevHeadFrame: String { "head_\(prevHead)" }
    var prevEyesFrame: String { "eyes_\(prevHead)_\(prevEyes)" }
    var prevMouthFrame: String { "mouth_\(prevHead)_\(prevMouth)" }

    /// Level quantizer with hysteresis: index i sits between bounds[i-1] and bounds[i].
    private static func quantize(_ v: Float, _ idx: Int, _ bounds: [Float], _ hys: Float) -> Int {
        var i = idx
        while i < bounds.count && v > bounds[i] + hys { i += 1 }
        while i > 0 && v < bounds[i - 1] - hys { i -= 1 }
        return i
    }

    // MARK: 1) Natural blink

    private func startBlink(_ now: CFTimeInterval, double: Bool = false) {
        blinkStart = now
        blinkIsDouble = double
        // ~10 % of blinks are partial (lids stop around blink3) — reads as more human.
        blinkPeak = (!double && Float.random(in: 0...1) < 0.10) ? 0.72 : 1
    }

    /// Lid closure 0…1 from our own rhythm: random 2–6 s gaps, fast close, short hold, slower open,
    /// occasional double blink. Progresses through blink1 → blink2 → blink3 → closed via blinkBounds.
    private func naturalBlink(_ now: CFTimeInterval, active: Bool) -> Float {
        if blinkStart < 0, now >= nextBlinkAt { startBlink(now) }
        guard blinkStart >= 0 else { return 0 }
        let t = now - blinkStart
        let c = Self.blinkClose
        let h = blinkPeak < 1 ? 0.02 : Self.blinkHold
        let o = Self.blinkOpen
        let v: Double
        if t < c {
            let x = t / c; v = x * x                       // lid accelerates down
        } else if t < c + h {
            v = 1
        } else if t < c + h + o {
            let x = (t - c - h) / o; v = (1 - x) * (1 - x) // lid eases back up
        } else {
            blinkStart = -1
            lastOwnBlinkEnd = now
            if !blinkIsDouble && Float.random(in: 0...1) < 0.12 {
                nextBlinkAt = now + Double.random(in: 0.10...0.22)     // quick double blink
                pendingDouble = true                                    // follow-up never chains
            } else {
                // Slightly more frequent while talking/listening (humans blink more in conversation).
                nextBlinkAt = now + (active ? Double.random(in: 2.0...5.0) : Double.random(in: 2.5...6.0))
            }
            return 0
        }
        return Float(v) * blinkPeak
    }
    private var pendingDouble = false

    /// Blend own rhythm with the external blink channel (LipSyncEngine.eyeBlink — FaceTracker has no
    /// blink signal today; any future one should be max-ed in here too). External blinks that land
    /// right after one of ours are ignored so two schedulers never produce a mechanical flutter.
    private func blinkValue(_ now: CFTimeInterval, external: Float, active: Bool) -> Float {
        if blinkStart < 0, pendingDouble, now >= nextBlinkAt {
            pendingDouble = false
            startBlink(now, double: true)
        }
        let own = naturalBlink(now, active: active)
        if external > 0.02 {
            if !extBlinkActive {
                extBlinkActive = true
                extBlinkAccepted = blinkStart < 0 && !pendingDouble && (now - lastOwnBlinkEnd) > 1.2
                if extBlinkAccepted {
                    // Count it as our blink: push our next one out so the rhythm stays 2–6 s.
                    nextBlinkAt = max(nextBlinkAt, now + Double.random(in: 2.5...6.0))
                }
            }
        } else {
            extBlinkActive = false
            extBlinkAccepted = false
        }
        return max(own, extBlinkAccepted ? external : 0)
    }

    // MARK: 4) Thinking expression

    private func beginThinking(_ now: CFTimeInterval) {
        // (eyes frame, head yaw bias, visual lift) — look up / up-side like recalling an answer.
        let options: [(String, Float, Float)] = [
            ("up2", 0, 1), ("up2", 0, 1), ("up1", 0, 0.7),
            ("left2", -0.07, 0.3), ("right2", 0.07, 0.3)
        ]
        let pick = options.randomElement() ?? ("up2", 0, 1)
        thinkEyes = pick.0
        thinkHeadBias = pick.1
        thinkLift = pick.2
        thinkStart = now
        thinkUntil = now + Double.random(in: 0.45...0.75)
        thinkCooldownUntil = now + 2.5
    }

    // MARK: Tick

    private func tick() {
        guard let engine, let tracker else { return }
        let now = CACurrentMediaTime()
        let dt = max(0, min(0.1, now - lastTick))
        lastTick = now
        let w = engine.weights

        // Activity: speaking unlock OR audio energy above the speak gate.
        let active = engine.speakingUnlocked || w.energy > Self.activeGate
        if active {
            if !wasActive, now - lastActiveAt >= Self.thinkQuietMin, now >= thinkCooldownUntil {
                beginThinking(now)   // 4) rising edge after a quiet gap
            }
            lastActiveAt = now
        }
        wasActive = active
        let silentFor = now - lastActiveAt

        // Thinking envelope (0 → 1 → 0 over the think window)
        let thinking = now < thinkUntil
        var thinkEnv: Float = 0
        if thinking {
            let dur = max(0.001, thinkUntil - thinkStart)
            thinkEnv = Float(sin(Double.pi * min(1, (now - thinkStart) / dur)))
        } else if mood == "think" {
            // Gaze returns to the viewer — people often blink on a big gaze shift.
            if blinkStart < 0, now - lastOwnBlinkEnd > 1.0, Float.random(in: 0...1) < 0.35 { nextBlinkAt = now }
        }

        // 2) / 3) Sway envelope: talking → lively; just stopped → softer, slower; long quiet → mild idle.
        let ampT: Float, rateT: Float, tau: Float
        if active {
            ampT = 1.0; rateT = 1.0; tau = 0.35
        } else if silentFor < 2.5 {
            ampT = 0.55; rateT = 0.6; tau = 0.9          // between sentences — don't freeze
        } else {
            ampT = 0.32; rateT = 0.4; tau = 1.8          // decayed, continuous mild idle
        }
        let k = 1 - exp(-Float(dt) / tau)
        swayAmp += (ampT - swayAmp) * k
        swayRate += (rateT - swayRate) * k
        let twoPi = 2 * Double.pi
        swayPh1 = (swayPh1 + dt * twoPi * 0.42 * Double(swayRate)).truncatingRemainder(dividingBy: twoPi)
        swayPh2 = (swayPh2 + dt * twoPi * 0.17 * Double(swayRate)).truncatingRemainder(dividingBy: twoPi)
        swayPh3 = (swayPh3 + dt * twoPi * 0.29 * Double(swayRate)).truncatingRemainder(dividingBy: twoPi)
        bobPh = (bobPh + dt * twoPi * (0.25 + 0.75 * Double(swayRate))).truncatingRemainder(dividingBy: twoPi)
        jawSmooth += (w.jawOpen - jawSmooth) * (1 - exp(-Float(dt) / 0.12))

        // Yaw sway (−1…1 head space). Peaks while talking occasionally tip center ↔ left1/right1.
        let yawSway = swayAmp * (0.15 * Float(sin(swayPh1)) + 0.06 * Float(sin(swayPh2 + 1.3)))
        // Pitch bob (no pitch head sprites → rendered as a gentle nod of the whole stack).
        let bob = swayAmp * (0.6 * Float(sin(bobPh)) + 0.4 * Float(sin(swayPh3)))
            + (active ? jawSmooth * 0.45 : 0)            // tiny dip on louder syllables

        swayRoll = Double(yawSway) * 6.0 + Double(thinkHeadBias * thinkEnv) * 10.0
        swayDX = Double(yawSway) * 0.03
        swayDY = Double(bob) * 0.008 - Double(thinkLift * thinkEnv) * 0.007

        // Window position relative to estimated camera (top-center): eyes stay on the viewer.
        let win = ViewerParallax.offset(for: ViewerParallax.avatarWindow())
        smoothWinYaw += (win.yaw - smoothWinYaw) * winEma
        smoothWinPitch += (win.pitch - smoothWinPitch) * winEma

        // Eyes = face tracking + window parallax. Head leans only lightly with the window.
        // Sway is added to the HEAD only, so gaze stays locked on the viewer (VOR-like).
        let eyeYaw = max(-1, min(1, tracker.yaw + smoothWinYaw))
        let eyePitch = max(-1, min(1, tracker.pitch + smoothWinPitch))
        let headYaw = max(-1, min(1, tracker.yaw + smoothWinYaw * 0.35 + yawSway + thinkHeadBias * thinkEnv))

        yawIdx = Self.quantize(headYaw, yawIdx, Self.yawBounds, Self.yawHys)
        lookIdx = Self.quantize(eyeYaw, lookIdx, Self.lookBounds, Self.lookHys)
        pitchIdx = Self.quantize(eyePitch, pitchIdx, Self.pitchBounds, Self.pitchHys)
        let lid = blinkValue(now, external: w.eyeBlink, active: active)
        blinkIdx = Self.quantize(lid, blinkIdx, Self.blinkBounds, Self.blinkHys)
        // Mouth ONLY follows real jawOpen from LipSyncEngine — never idle/random.
        if w.jawOpen < Self.jawClosedMax {
            jawIdx = 0
        } else {
            jawIdx = Self.quantize(w.jawOpen, jawIdx, Self.jawBounds, Self.jawHys)
        }

        var gx = lookIdx, gy = pitchIdx
        // When camera finds no face, window parallax still drives the eyes.
        // Soft idle glances only when the window is near the camera (nearly frontal).
        if !tracker.faceDetected {
            let nearFront = abs(smoothWinYaw) < 0.12 && abs(smoothWinPitch) < 0.12
            if nearFront {
                if now >= nextGlanceAt {
                    let options = [(2, 3), (1, 3), (0, 3), (4, 3), (5, 3), (6, 3), (3, 4), (3, 5), (3, 2), (2, 4), (4, 4)]
                    glance = options.randomElement() ?? (3, 3)
                    glanceUntil = now + Double.random(in: 0.7...1.3)
                    nextGlanceAt = now + Double.random(in: 3.0...6.0)
                }
                if now < glanceUntil { gx = glance.x; gy = glance.y }
            }
        }

        let newHead = Self.heads[yawIdx]
        let newEyes: String
        if blinkIdx > 0 { newEyes = Self.blinks[blinkIdx] }
        else if thinking { newEyes = (now - thinkStart) < 0.09 ? "blink1" : thinkEyes }   // brief lid/brow dip, then look away
        else if gx != Self.centerIdx { newEyes = Self.eyesX[gx] }
        else if gy != Self.centerIdx { newEyes = Self.eyesY[gy] }
        else { newEyes = "center" }
        let newMouth = Self.mouths[jawIdx]

        if newHead != head || newEyes != eyes || newMouth != mouth {
            if newHead != head || newEyes != eyes {
                // Freeze head/eyes for crossfade only — mouth never participates in the blend
                // (blending mouth_H1_o0 with mouth_H2_o0 ghosts a wider "talking" lip from the ~10px rect shift).
                if blend >= 0.5 { prevHead = head; prevEyes = eyes }
                fadeStart = now
                let blinkish = newEyes.hasPrefix("blink") || newEyes == "closed" || eyes.hasPrefix("blink") || eyes == "closed"
                fadeDur = blinkish ? 0.03 : (newHead != head ? 0.09 : 0.05)
                blend = 0
            }
            head = newHead
            eyes = newEyes
            mouth = newMouth
            prevMouth = newMouth  // mouth always snaps with current tier
        }
        if blend < 1 {
            blend = min(1, (now - fadeStart) / max(0.001, fadeDur))
            if blend >= 1 { prevHead = head; prevEyes = eyes; prevMouth = mouth }
        }
        glow += (Double(w.jawOpen) - glow) * 0.2

        let newMood = thinking ? "think" : (active ? "talk" : (silentFor < 2.5 ? "pause" : "idle"))
        if newMood != mood { mood = newMood }
    }
}

// MARK: - View

/// Large 2D anime face driven by baked VN sprite layers (no runtime overlay drawing).
struct AnimeFaceView: View {
    @ObservedObject var engine: LipSyncEngine
    @ObservedObject var faceTracker: FaceTracker
    @StateObject private var driver = SpriteDriver()
    private let bank = SpriteBank.shared

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.98
            let k = side / bank.canvas
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.07, alpha: 1))

                Circle()
                    .fill(Color(red: 1.0, green: 0.4, blue: 0.85).opacity(0.08 + 0.22 * driver.glow))
                    .blur(radius: side * 0.14)
                    .frame(width: side * 1.05, height: side * 1.05)

                ZStack(alignment: .topLeading) {
                    if bank.sprites.isEmpty {
                        fallbackFace.frame(width: side, height: side)
                    } else {
                        // Head + eyes crossfade only. Mouth is drawn once on top at full opacity
                        // so head-turn blends cannot ghost two o0 crops into a "talking" mouth.
                        layer(driver.prevHeadFrame, k)
                        layer(driver.prevEyesFrame, k)
                        ZStack(alignment: .topLeading) {
                            layer(driver.headFrame, k)
                            layer(driver.eyesFrame, k)
                        }
                        .frame(width: side, height: side, alignment: .topLeading)
                        .opacity(driver.blend)
                        layer(driver.mouthFrame, k)
                    }
                }
                .frame(width: side, height: side, alignment: .topLeading)
                // Liveliness sway/bob: whole stack (head+eyes+mouth) moves together; slight
                // overscale keeps the opaque head base filling the circle at the sway extremes.
                .scaleEffect(1.03)
                .rotationEffect(.degrees(driver.swayRoll))
                .offset(x: side * driver.swayDX, y: side * driver.swayDY)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)

                VStack {
                    HStack {
                        Text("VN · \(driver.head) · eyes \(driver.eyes) · mouth \(driver.mouth) · \(driver.mood)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { driver.attach(engine: engine, tracker: faceTracker) }
        .onDisappear { driver.detach() }
    }

    /// Places a sprite at its manifest rect (canvas px → points via scale k).
    @ViewBuilder
    private func layer(_ name: String, _ k: CGFloat) -> some View {
        if let s = bank.sprite(name) {
            Image(decorative: s.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: s.rect.width * k, height: s.rect.height * k)
                .offset(x: s.rect.minX * k, y: s.rect.minY * k)
        }
    }

    private var fallbackFace: some View {
        Group {
            if let url = Bundle.main.url(forResource: "anime-face", withExtension: "jpg"),
               let ns = NSImage(contentsOf: url) {
                Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "face.smiling").resizable().scaledToFit().padding(80)
            }
        }
    }
}
