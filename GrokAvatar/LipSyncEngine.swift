import Foundation
import Combine
import QuartzCore
import AppKit

/// Maps system-audio analysis to facial controls at ~60 Hz.
/// Idle stays mouth-closed (o0); opens only on sustained audio above noise floor.
final class LipSyncEngine: ObservableObject {
    struct Weights: Equatable {
        var jawOpen: Float = 0
        var mouthWidth: Float = 0.5
        var eyeBlink: Float = 0
        var eyeWiden: Float = 0
        var energy: Float = 0
    }

    @Published private(set) var weights = Weights()
    @Published private(set) var statusNote = "Starting…"
    @Published private(set) var captureOK = false
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var rawRms: Float = 0
    @Published private(set) var packetCount: UInt64 = 0

    /// When false, mouth morphs stay neutral (jaw closed); blink still runs.
    @Published var lipSyncEnabled: Bool = true

    var audioFlowing: Bool { packetCount > 0 }

    private var capture: SystemAudioCapture?
    private var tickTimer: Timer?
    private var started = false

    private var energyEnv: Float = 0
    private var jawEnv: Float = 0
    private var widthEnv: Float = 0.5
    private var widenEnv: Float = 0

    // Noise floor / gating — mouth opens only on clear speech, not ambient/fan/UI.
    private let speakGate: Float = 0.022
    /// Higher bar to *start* opening; once unlocked, speakGate holds it.
    private let openConfirmGate: Float = 0.030
    /// Frames (~60 Hz) above openConfirmGate required before mouth unlocks.
    private let openHoldFrames: Int = 8
    /// Asymmetric envelope: slower attack, fast release when quiet.
    private let attack: Float = 0.22
    private let release: Float = 0.70
    private let quietRelease: Float = 0.88
    /// Quiet speech → o1–o2; loud → o5–o7 (with SpriteDriver jawBounds).
    private let jawGain: Float = 12.0
    /// Slow adaptive floor from quiet packets; speak must clear floor*ratio too.
    private var noiseFloor: Float = 0.004
    private let noiseFloorAlpha: Float = 0.04
    private let noiseFloorRatio: Float = 3.5

    private var aboveGateFrames: Int = 0
    private var speakingUnlocked = false

    private var nextBlinkAt = Date().addingTimeInterval(2.5)
    private var blinkPhase: Float = 0
    private var blinkAmount: Float = 0

    private let lock = NSLock()
    private var latest = SystemAudioCapture.Analysis(rms: 0, low: 0, mid: 0, high: 0)
    private var lastAudioTime = CACurrentMediaTime()
    private var captureStartedAt: TimeInterval = 0
    private var localPacketCount: UInt64 = 0
    private var warnedNoPackets = false
    private var lastLogAt: TimeInterval = 0
    private var nonSilentPackets: UInt64 = 0
    private var loggedMode: String = ""

    // Smoke / demo mouth wiggle permanently disabled — mouth stays o0 until real speech.
    private var smokeUntil: TimeInterval = 0
    private let smokeDuration: TimeInterval = 0

    private let logURL = URL(fileURLWithPath: NSString("~/GrokAvatar/lip-sync-debug.log").expandingTildeInPath)

    func start() {
        guard !started else { return }
        started = true
        smokeUntil = 0
        lastAudioTime = CACurrentMediaTime()
        aboveGateFrames = 0
        speakingUnlocked = false
        energyEnv = 0
        jawEnv = 0
        noiseFloor = 0.004
        loggedMode = ""
        appendLog("engine start — no smoke/demo; mouth o0 until speech above gate")
        startCapture()
        startTickTimer()
    }

    func stop() {
        started = false
        stopTickTimer()
        capture?.stop()
        capture = nil
        appendLog("engine stop")
    }

    private func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row = "\(stamp) \(line)\n"
        if let data = row.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) {
                    defer { try? h.close() }
                    h.seekToEndOfFile()
                    h.write(data)
                }
            } else {
                try? data.write(to: logURL)
            }
        }
        NSLog("GrokAvatar LipSync: %@", line)
    }

    private func logModeOnce(_ mode: String, detail: String) {
        guard mode != loggedMode else { return }
        loggedMode = mode
        appendLog("MODE=\(mode) \(detail)")
    }

    private func startCapture() {
        let cap = SystemAudioCapture { [weak self] analysis in
            guard let self else { return }
            self.lock.lock()
            self.latest = analysis
            self.lastAudioTime = CACurrentMediaTime()
            self.localPacketCount &+= 1
            if analysis.rms > self.speakGate { self.nonSilentPackets &+= 1 }
            let pkts = self.localPacketCount
            let nons = self.nonSilentPackets
            let rms = analysis.rms
            self.lock.unlock()
            DispatchQueue.main.async {
                self.packetCount = pkts
                self.rawRms = rms
            }
            let now = CACurrentMediaTime()
            if rms > self.speakGate, now - self.lastLogAt > 0.35 {
                self.lastLogAt = now
                self.appendLog(String(format: "PCM rms=%.5f pkts=%llu nonSilent=%llu", rms, pkts, nons))
            }
        }
        capture = cap
        Task { @MainActor in
            do {
                try await cap.start()
                self.captureOK = true
                self.captureStartedAt = CACurrentMediaTime()
                self.warnedNoPackets = false
                self.statusNote = "Capture OK · listening"
                self.appendLog("ScreenCaptureKit start OK — LIVE capture")
                self.logModeOnce("LIVE", detail: "capture OK, waiting for packets")
            } catch {
                self.captureOK = false
                self.statusNote = "Grant Screen Recording — mouth idle until live"
                self.appendLog("capture FAIL: \(error.localizedDescription)")
                self.logModeOnce("IDLE_NO_CAPTURE", detail: "Screen Recording denied/failed — mouth closed (no demo)")
            }
        }
    }

    private func startTickTimer() {
        stopTickTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        lock.lock()
        let a = latest
        let audioAgeMs = (CACurrentMediaTime() - lastAudioTime) * 1000
        let pkts = localPacketCount
        lock.unlock()

        let now = CACurrentMediaTime()

        // Smoke disabled (smokeUntil always 0) — never synthesize jaw motion.
        if !lipSyncEnabled {
            updateBlink()
            resetMouthEnvelopes()
            weights = Weights(jawOpen: 0, mouthWidth: 0.5, eyeBlink: blinkAmount, eyeWiden: 0, energy: 0)
            statusNote = "Lip sync OFF"
            latencyMs = audioAgeMs
            return
        }

        // No live system audio — keep mouth CLOSED (no continuous demo wiggle).
        if !captureOK || pkts == 0 {
            if captureOK {
                let elapsed = now - captureStartedAt
                if elapsed > 2.5 && !warnedNoPackets {
                    warnedNoPackets = true
                    statusNote = "No audio packets — enable Screen Recording for GrokAvatar, then relaunch"
                    appendLog("WATCHDOG: 0 packets after 2.5s — Screen Recording likely denied")
                    logModeOnce("IDLE_NO_PACKETS", detail: "capture OK but 0 packets — mouth closed")
                } else if elapsed <= 2.5 {
                    statusNote = "Capture OK · waiting for audio…"
                }
            } else {
                if !warnedNoPackets {
                    warnedNoPackets = true
                    appendLog("WATCHDOG: capture not OK — mouth idle (demo lips DISABLED)")
                }
                logModeOnce("IDLE_NO_CAPTURE", detail: "demo lips disabled — grant Screen Recording for live sync")
                statusNote = "Idle · grant Screen Recording for live lip-sync"
            }
            updateBlink()
            resetMouthEnvelopes()
            weights = Weights(jawOpen: 0, mouthWidth: 0.5, eyeBlink: blinkAmount, eyeWiden: 0, energy: 0)
            latencyMs = audioAgeMs
            return
        }

        let effectiveGate = max(speakGate, noiseFloor * noiseFloorRatio)
        let effectiveConfirm = max(openConfirmGate, effectiveGate * 1.25)
        logModeOnce("LIVE", detail: String(format: "pkts=%llu gate=%.4f floor=%.5f", pkts, effectiveGate, noiseFloor))

        let raw = a.rms
        // Adaptive noise floor: only learn from clearly quiet packets.
        if raw < speakGate * 0.85 {
            noiseFloor += (raw - noiseFloor) * noiseFloorAlpha
            noiseFloor = max(0.001, min(noiseFloor, speakGate * 0.7))
        }

        if raw > energyEnv {
            energyEnv += (raw - energyEnv) * attack
        } else {
            energyEnv += (raw - energyEnv) * release
        }

        // Sustained-audio unlock: several frames above confirm gate (speech, not blips).
        if energyEnv >= effectiveConfirm {
            aboveGateFrames = min(openHoldFrames + 2, aboveGateFrames + 1)
            if aboveGateFrames >= openHoldFrames {
                speakingUnlocked = true
            }
        } else if energyEnv < effectiveGate {
            aboveGateFrames = 0
            speakingUnlocked = false
        } else {
            aboveGateFrames = max(0, aboveGateFrames - 1)
            if aboveGateFrames == 0 { speakingUnlocked = false }
        }

        var jawTarget: Float = 0
        if speakingUnlocked {
            let gated = max(0, energyEnv - effectiveGate)
            jawTarget = min(1, gated * jawGain)
            if energyEnv >= 0.055 {
                jawTarget = max(jawTarget, min(1.0, (energyEnv - 0.035) * 16))
            }
        }

        if jawTarget > jawEnv {
            jawEnv += (jawTarget - jawEnv) * attack
        } else {
            let rel = energyEnv < effectiveGate ? quietRelease : release
            jawEnv += (jawTarget - jawEnv) * rel
        }
        // Hard close whenever not unlocked or below gate — no residual jaw wiggle.
        if !speakingUnlocked || energyEnv < effectiveGate {
            jawEnv = 0
            widthEnv = 0.5
            widenEnv = 0
        } else if jawEnv < 0.03 {
            jawEnv = 0
        }

        let bandSum = a.mid + a.high + 1e-6
        let highRatio = a.high / bandSum
        let widthTarget: Float = jawTarget < 0.05 ? 0.5 : (0.75 - highRatio * 0.55)
        if speakingUnlocked {
            widthEnv += (widthTarget - widthEnv) * 0.25
            let widenTarget: Float = energyEnv > 0.06 ? min(1, (energyEnv - 0.06) * 10) : 0
            widenEnv += (widenTarget - widenEnv) * 0.3
        }

        updateBlink()

        let w = Weights(
            jawOpen: jawEnv,
            mouthWidth: widthEnv,
            eyeBlink: blinkAmount,
            eyeWiden: widenEnv,
            energy: energyEnv
        )
        weights = w
        latencyMs = audioAgeMs

        if jawEnv > 0.08 {
            statusNote = String(format: "LIVE · Talking · rms %.4f · jaw %.2f · pkts %llu", energyEnv, jawEnv, pkts)
        } else {
            statusNote = String(format: "LIVE · Idle · rms %.4f · floor %.4f · pkts %llu", energyEnv, noiseFloor, pkts)
        }
    }

    private func resetMouthEnvelopes() {
        energyEnv = 0
        jawEnv = 0
        widthEnv = 0.5
        widenEnv = 0
        aboveGateFrames = 0
        speakingUnlocked = false
    }

    private func updateBlink() {
        let now = Date()
        if blinkPhase <= 0, now >= nextBlinkAt {
            blinkPhase = 0.001
        }
        if blinkPhase > 0 {
            blinkPhase += 1.0 / 12.0
            if blinkPhase >= 1 {
                blinkPhase = 0
                blinkAmount = 0
                nextBlinkAt = now.addingTimeInterval(Double.random(in: 2.0...5.5))
            } else {
                let t = blinkPhase
                blinkAmount = t < 0.45 ? (t / 0.45) : max(0, 1 - (t - 0.45) / 0.55)
            }
        }
    }
}
