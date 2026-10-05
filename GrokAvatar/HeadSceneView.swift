import SwiftUI
import SceneKit
import AppKit
import Combine
import QuartzCore


/// SCNView eats mouse events, so isMovableByWindowBackground never fires.
/// Forward primary-button downs to the window drag machinery.
final class DraggableSCNView: SCNView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct HeadSceneView: NSViewRepresentable {
    @ObservedObject var engine: LipSyncEngine
    @ObservedObject var faceTracker: FaceTracker

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine, faceTracker: faceTracker)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = DraggableSCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        context.coordinator.scnView = view
        context.coordinator.startApplying()
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.engine = engine
        context.coordinator.faceTracker = faceTracker
    }

    final class Coordinator {
        var engine: LipSyncEngine
        var faceTracker: FaceTracker
        let scene = SCNScene()
        let rig = HeadRig()
        weak var scnView: SCNView?
        private var timer: Timer?
        private var currentYaw: Float = 0
        private var currentPitch: Float = 0
        private var idlePhase: Float = 0
        private var breathPhase: Float = 0
        private var blinkUntil: TimeInterval = 0
        private var nextBlinkAt: TimeInterval = CACurrentMediaTime() + 2.5
        private var blinkAmount: Float = 0
        private let maxYaw: Float = 0.18
        private let maxPitch: Float = 0.10
        private let headLerp: Float = 0.12

        init(engine: LipSyncEngine, faceTracker: FaceTracker) {
            self.engine = engine
            self.faceTracker = faceTracker
            setupScene()
        }

        private func setupScene() {
            scene.background.contents = NSColor(calibratedWhite: 0.08, alpha: 1)

            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 42
            cameraNode.position = SCNVector3(0, 0.0, 2.2)
            scene.rootNode.addChildNode(cameraNode)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 1100
            key.light?.color = NSColor(calibratedWhite: 1.0, alpha: 1)
            key.eulerAngles = SCNVector3(-0.4, 0.5, 0)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .directional
            fill.light?.intensity = 520
            fill.light?.color = NSColor(calibratedRed: 0.7, green: 0.8, blue: 1.0, alpha: 1)
            fill.eulerAngles = SCNVector3(-0.2, -0.8, 0)
            scene.rootNode.addChildNode(fill)

            let amb = SCNNode()
            amb.light = SCNLight()
            amb.light?.type = .ambient
            amb.light?.intensity = 380
            amb.light?.color = NSColor(calibratedWhite: 1.0, alpha: 1)
            amb.name = "ambientLight"
            scene.rootNode.addChildNode(amb)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 320
            ambient.light?.color = NSColor(calibratedWhite: 0.55, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .directional
            rim.light?.intensity = 400
            rim.light?.color = NSColor(calibratedRed: 0.85, green: 0.9, blue: 1.0, alpha: 1)
            rim.eulerAngles = SCNVector3(0.2, 2.6, 0)
            scene.rootNode.addChildNode(rim)

            rig.root.position = SCNVector3(0, -0.02, 0)
            scene.rootNode.addChildNode(rig.root)
        }

        func startApplying() {
            timer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let tracker = self.faceTracker
                let now = CACurrentMediaTime()
                // Idle breath + periodic blink (morph weights)
                self.breathPhase += 0.025
                let breath: Float = 0  // body breath off
                if now >= self.nextBlinkAt {
                    self.blinkUntil = now + 0.14
                    self.nextBlinkAt = now + Double.random(in: 2.2...5.5)
                }
                if now < self.blinkUntil {
                    self.blinkAmount = 1
                } else {
                    self.blinkAmount *= 0.75
                    if self.blinkAmount < 0.02 { self.blinkAmount = 0 }
                }
                let idle = HeadRig.IdleExtras(breath: breath, blink: self.blinkAmount)
                let gaze = Gaze(lookX: tracker.yaw, lookY: tracker.pitch)
                self.rig.apply(self.engine.weights, gaze: gaze, idle: idle)

                // Head: face tracking overrides; else idle micro tilts/nods
                self.idlePhase += 0.01
                let idleYaw = sin(self.idlePhase) * 0.02
                let idlePitch = sin(self.idlePhase * 0.63) * 0.01
                let targetYaw: Float
                let targetPitch: Float
                if tracker.faceDetected {
                    targetYaw = tracker.yaw * self.maxYaw
                    targetPitch = tracker.pitch * self.maxPitch
                } else {
                    targetYaw = idleYaw
                    targetPitch = idlePitch
                }
                self.currentYaw += (targetYaw - self.currentYaw) * self.headLerp
                self.currentPitch += (targetPitch - self.currentPitch) * self.headLerp
                self.rig.root.eulerAngles.y = CGFloat(self.currentYaw)
                self.rig.root.eulerAngles.x = CGFloat(self.currentPitch)
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        deinit {
            timer?.invalidate()
        }
    }
}
