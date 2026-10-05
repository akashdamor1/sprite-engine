import SwiftUI
import AppKit
import ImageIO
import QuartzCore

// MARK: - Sprite bank

/// Loads the baked VN sprite layers (Models/sprites → app Resources/sprites) once, fully decoded.
///
/// v3 extra-dense set (canvas 1024×1024, crops positioned by `sprite_manifest.json` rects):
///   head_{left3|left2|left1|center|right1|right2|right3}.png         opaque head bases (7)
///   eyes_{H}_{center|left1-3|right1-3|up1-3|down1-3|blink1-3|closed}.png  eye-band crops (7×17 = 119)
///   mouth_{H}_{o0…o7}.png                                             mouth crops, 8 openness tiers (7×8 = 56)
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

// MARK: - Frame selection (inputs → frame names, with hysteresis + short crossfade)

final class SpriteDriver: ObservableObject {
    static let heads = ["left3", "left2", "left1", "center", "right1", "right2", "right3"]   // yaw level -3…+3
    static let eyesX = ["left3", "left2", "left1", "center", "right1", "right2", "right3"]   // look level -3…+3
    static let eyesY = ["down3", "down2", "down1", "center", "up1", "up2", "up3"]            // pitch level -3…+3
    static let blinks = ["open", "blink1", "blink2", "blink3", "closed"]                       // lid 0 / 22 / 45 / 70 / 100 %
    static let mouths = ["o0", "o1", "o2", "o3", "o4", "o5", "o6", "o7"]                       // jaw tier 0…7
    static let centerIdx = 3

    // Thresholds (boundaries between neighbouring levels) + hysteresis margin
    private static let yawBounds: [Float] = [-0.62, -0.38, -0.15, 0.15, 0.38, 0.62];   private static let yawHys: Float = 0.03
    private static let lookBounds: [Float] = [-0.40, -0.24, -0.09, 0.09, 0.24, 0.40];  private static let lookHys: Float = 0.025
    private static let pitchBounds: [Float] = [-0.45, -0.28, -0.12, 0.12, 0.28, 0.45]; private static let pitchHys: Float = 0.03
    private static let blinkBounds: [Float] = [0.15, 0.38, 0.60, 0.82];                private static let blinkHys: Float = 0.03
    private static let jawBounds: [Float] = [0.04, 0.10, 0.16, 0.23, 0.30, 0.38, 0.47]; private static let jawHys: Float = 0.015

    @Published private(set) var head = "center"
    @Published private(set) var eyes = "center"
    @Published private(set) var mouth = "o0"
    @Published private(set) var prevHead = "center"
    @Published private(set) var prevEyes = "center"
    @Published private(set) var prevMouth = "o0"
    @Published private(set) var blend: Double = 1      // 0 → show prev frame, 1 → current frame
    @Published private(set) var glow: Double = 0

    private weak var engine: LipSyncEngine?
    private weak var tracker: FaceTracker?
    private var timer: Timer?

    // quantizer state (indices into the arrays above)
    private var yawIdx = 3, lookIdx = 3, pitchIdx = 3, blinkIdx = 0, jawIdx = 0
    private var fadeStart: CFTimeInterval = 0
    private var fadeDur: CFTimeInterval = 0.1

    // idle glances when no face is tracked (VN-style "alive" eyes)
    private var nextGlanceAt = CACurrentMediaTime() + 2.5
    private var glanceUntil: CFTimeInterval = 0
    private var glance = (x: 3, y: 3)

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

    private func tick() {
        guard let engine, let tracker else { return }
        let now = CACurrentMediaTime()
        let w = engine.weights

        yawIdx = Self.quantize(tracker.yaw, yawIdx, Self.yawBounds, Self.yawHys)
        lookIdx = Self.quantize(tracker.yaw, lookIdx, Self.lookBounds, Self.lookHys)
        pitchIdx = Self.quantize(tracker.pitch, pitchIdx, Self.pitchBounds, Self.pitchHys)
        blinkIdx = Self.quantize(w.eyeBlink, blinkIdx, Self.blinkBounds, Self.blinkHys)
        jawIdx = Self.quantize(w.jawOpen, jawIdx, Self.jawBounds, Self.jawHys)

        var gx = lookIdx, gy = pitchIdx
        if !tracker.faceDetected {
            if now >= nextGlanceAt {
                let options = [(2, 3), (1, 3), (0, 3), (4, 3), (5, 3), (6, 3), (3, 4), (3, 5), (3, 2), (2, 4), (4, 4)]
                glance = options.randomElement() ?? (3, 3)
                glanceUntil = now + Double.random(in: 0.7...1.3)
                nextGlanceAt = now + Double.random(in: 3.0...6.0)
            }
            if now < glanceUntil { gx = glance.x; gy = glance.y }
        }

        let newHead = Self.heads[yawIdx]
        let newEyes: String
        if blinkIdx > 0 { newEyes = Self.blinks[blinkIdx] }
        else if gx != Self.centerIdx { newEyes = Self.eyesX[gx] }
        else if gy != Self.centerIdx { newEyes = Self.eyesY[gy] }
        else { newEyes = "center" }
        let newMouth = Self.mouths[jawIdx]

        if newHead != head || newEyes != eyes || newMouth != mouth {
            if newHead != head || newEyes != eyes {
                // freeze what is currently (mostly) visible as the underlay, fade the new frame in
                if blend >= 0.5 { prevHead = head; prevEyes = eyes; prevMouth = mouth }
                fadeStart = now
                let blinkish = newEyes.hasPrefix("blink") || newEyes == "closed" || eyes.hasPrefix("blink") || eyes == "closed"
                fadeDur = blinkish ? 0.03 : (newHead != head ? 0.09 : 0.05)
                blend = 0
            } else if blend >= 1 {
                prevMouth = newMouth   // mouth alone snaps (crisp VN lip flaps, 8 tiers)
            }
            head = newHead
            eyes = newEyes
            mouth = newMouth
        }
        if blend < 1 {
            blend = min(1, (now - fadeStart) / max(0.001, fadeDur))
            if blend >= 1 { prevHead = head; prevEyes = eyes; prevMouth = mouth }
        }
        glow += (Double(w.jawOpen) - glow) * 0.2
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
                        layer(driver.prevHeadFrame, k)
                        layer(driver.prevEyesFrame, k)
                        layer(driver.prevMouthFrame, k)
                        ZStack(alignment: .topLeading) {
                            layer(driver.headFrame, k)
                            layer(driver.eyesFrame, k)
                            layer(driver.mouthFrame, k)
                        }
                        .frame(width: side, height: side, alignment: .topLeading)
                        .opacity(driver.blend)
                    }
                }
                .frame(width: side, height: side, alignment: .topLeading)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)

                VStack {
                    HStack {
                        Text("VN · \(driver.head) · eyes \(driver.eyes) · mouth \(driver.mouth)")
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
