import Foundation
import Combine
import QuartzCore
import AppKit

/// Maps system-audio analysis to facial controls at ~60 Hz.
/// Crude mode: any audio above threshold → jawOpen = 1.0, else 0 (verifies capture→apply).
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

    // Crude binary threshold test (isolates capture vs apply)
    private let crudeOpenThreshold: Float = 0.004
    private let attack: Float = 0.42
    private let release: Float = 0.38
    private let jawGain: Float = 42.0
    private let speakGate: Float = 0.0012

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

    // Smoke-test: animate jaw on launch to prove SceneKit apply works
    private var smokeUntil: TimeInterval = 0

    private let logURL = URL(fileURLWithPath: NSString("~/GrokAvatar/lip-sync-debug.log").expandingTildeInPath)

    func start() {
        guard !started else { return }
        started = true
        smokeUntil = CACurrentMediaTime() + 3.0
        lastAudioTime = CACurrentMediaTime()
        appendLog("engine start — smoke test 2s then live lip-sync")
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

    private func startCapture() {
        let cap = SystemAudioCapture { [weak self] analysis in
            guard let self else { return }
            self.lock.lock()
            self.latest = analysis
            self.lastAudioTime = CACurrentMediaTime()
            self.localPacketCount &+= 1
            if analysis.rms > 0.0008 { self.nonSilentPackets &+= 1 }
            let pkts = self.localPacketCount
            let nons = self.nonSilentPackets
            let rms = analysis.rms
            self.lock.unlock()
            DispatchQueue.main.async {
                self.packetCount = pkts
                self.rawRms = rms
            }
            // Throttled file log when non-silent
            let now = CACurrentMediaTime()
            if rms > 0.0008, now - self.lastLogAt > 0.35 {
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
                self.statusNote = "Capture OK · smoke then live"
                self.appendLog("ScreenCaptureKit start OK")
            } catch {
                self.captureOK = false
                self.statusNote = "Grant Screen Recording — \(error.localizedDescription)"
                self.appendLog("capture FAIL: \(error.localizedDescription)")
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
        let _ = nonSilentPackets
        lock.unlock()

        let now = CACurrentMediaTime()

        // --- Launch smoke test: force jaw open/close so SceneKit path is proven ---
        if now < smokeUntil && lipSyncEnabled {
            let phase = (smokeUntil - now) / 3.0
            // Gentle open/close so we can verify mouth lands on the painted lips
            let pulse = Float(0.25 + 0.55 * abs(sin((1 - phase) * .pi * 5)))
            updateBlink()
            weights = Weights(jawOpen: pulse, mouthWidth: 0.6, eyeBlink: blinkAmount, eyeWiden: 0.1, energy: pulse)
            statusNote = "SMOKE · mouth align check"
            latencyMs = audioAgeMs
            return
        }

        if !lipSyncEnabled {
            updateBlink()
            energyEnv = 0
            jawEnv = 0
            widthEnv = 0.5
            widenEnv = 0
            weights = Weights(jawOpen: 0, mouthWidth: 0.5, eyeBlink: blinkAmount, eyeWiden: 0, energy: 0)
            statusNote = "Lip sync OFF"
            latencyMs = audioAgeMs
            return
        }

        // No live system audio yet (denied Screen Recording, or capture up but silent packets)
        if !captureOK || pkts == 0 {
            if captureOK {
                let elapsed = now - captureStartedAt
                if elapsed > 2.5 && !warnedNoPackets {
                    warnedNoPackets = true
                    statusNote = "No audio packets — enable Screen Recording for GrokAvatar, then relaunch"
                    appendLog("WATCHDOG: 0 packets after 2.5s — Screen Recording likely denied")
                }
            } else if !warnedNoPackets {
                warnedNoPackets = true
                appendLog("WATCHDOG: capture not OK — demo lips until Screen Recording allowed")
            }
            // Demo speech-like mouth until Screen Recording grants live audio
            updateBlink()
            let syllable = abs(sin(now * 7.2)) * abs(sin(now * 3.1))
            let demo = Float(0.08 + 0.52 * Float(syllable))
            jawEnv = demo
            weights = Weights(jawOpen: demo, mouthWidth: 0.6, eyeBlink: blinkAmount, eyeWiden: 0.05, energy: demo * 0.02)
            statusNote = "DEMO lips (grant Screen Recording for live sync)"
            latencyMs = audioAgeMs
            return
        }

        let raw = a.rms
        if raw > energyEnv {
            energyEnv += (raw - energyEnv) * attack
        } else {
            energyEnv += (raw - energyEnv) * release
        }

        // Proportional jaw from energy (speech-like), with a soft boost when clearly speaking
        let gated = max(0, energyEnv - speakGate)
        var jawTarget = min(1, gated * jawGain)
        if energyEnv >= crudeOpenThreshold {
            jawTarget = max(jawTarget, min(0.85, energyEnv * 90))
        }

        if jawTarget > jawEnv {
            jawEnv += (jawTarget - jawEnv) * attack
        } else {
            let rel = energyEnv < speakGate ? max(release, 0.5) : release
            jawEnv += (jawTarget - jawEnv) * rel
        }
        if energyEnv < speakGate { jawEnv *= 0.82 }

        let bandSum = a.mid + a.high + 1e-6
        let highRatio = a.high / bandSum
        let widthTarget: Float = gated < 0.001 ? 0.5 : (0.75 - highRatio * 0.55)
        widthEnv += (widthTarget - widthEnv) * 0.25

        let widenTarget: Float = energyEnv > 0.045 ? min(1, (energyEnv - 0.045) * 12) : 0
        widenEnv += (widenTarget - widenEnv) * 0.3

        updateBlink()

        let w = Weights(
            jawOpen: jawEnv,
            mouthWidth: widthEnv,
            eyeBlink: blinkAmount,
            eyeWiden: widenEnv,
            energy: energyEnv
        )
        weights = w // always publish so SceneKit apply never stalls on Equatable
        latencyMs = audioAgeMs

        if captureOK && pkts > 0 {
            if jawEnv > 0.12 {
                statusNote = String(format: "Talking · rms %.4f · jaw %.2f · pkts %llu", energyEnv, jawEnv, pkts)
            } else {
                statusNote = String(format: "Idle · rms %.4f · pkts %llu · listening", energyEnv, pkts)
            }
        }
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
