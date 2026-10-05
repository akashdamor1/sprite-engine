import SceneKit
import AppKit
import Foundation

struct Gaze {
    var lookX: Float = 0
    var lookY: Float = 0
}

/// Primary: animated Tifa USDZ (jawOpen/blink/breath morphs + idle skeletal).
/// Fallback: static tifa_sexy, facecap ARKit, then sphere.
final class HeadRig {
    let root = SCNNode()
    private var morphNodes: [(SCNNode, SCNMorpher)] = []
    private var nameToIndex: [String: Int] = [:]
    private var fallback: HeadRigFallback?
    private var mouthCue: SCNNode?
    private var usesProceduralMouth = false
    private var modelContainer: SCNNode?
    private var idlePlaying = false
    private var smoothedJaw: Float = 0

    /// Extra idle morph weights driven by HeadSceneView (breath/blink).
    struct IdleExtras {
        var breath: Float = 0
        var blink: Float = 0
    }

    private let knownOrder = [
        "browInnerUp", "browDown_L", "browDown_R", "browOuterUp_L", "browOuterUp_R",
        "eyeLookUp_L", "eyeLookUp_R", "eyeLookDown_L", "eyeLookDown_R",
        "eyeLookIn_L", "eyeLookIn_R", "eyeLookOut_L", "eyeLookOut_R",
        "eyeBlink_L", "eyeBlink_R", "eyeSquint_L", "eyeSquint_R", "eyeWide_L", "eyeWide_R",
        "cheekPuff", "cheekSquint_L", "cheekSquint_R", "noseSneer_L", "noseSneer_R",
        "jawOpen", "jawForward", "jawLeft", "jawRight",
        "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
        "mouthRollUpper", "mouthRollLower", "mouthShrugUpper", "mouthShrugLower", "mouthClose",
        "mouthSmile_L", "mouthSmile_R", "mouthFrown_L", "mouthFrown_R",
        "mouthDimple_L", "mouthDimple_R", "mouthUpperUp_L", "mouthUpperUp_R",
        "mouthLowerDown_L", "mouthLowerDown_R", "mouthPress_L", "mouthPress_R",
        "mouthStretch_L", "mouthStretch_R", "tongueOut"
    ]

    init() {
        if loadUSDZ(name: "tifa_animated", preferEmbeddedMaterials: true, facecapOrient: false) {
            NSLog("GrokAvatar HeadRig: loaded tifa_animated morphs=%d proceduralMouth=%d",
                  morphNodes.count, usesProceduralMouth ? 1 : 0)
            playIdleAnimations()
            return
        }
        if loadUSDZ(name: "tifa_sexy", preferEmbeddedMaterials: true, facecapOrient: false) {
            NSLog("GrokAvatar HeadRig: loaded tifa_sexy morphs=%d proceduralMouth=%d",
                  morphNodes.count, usesProceduralMouth ? 1 : 0)
            return
        }
        if loadUSDZ(name: "facecap", preferEmbeddedMaterials: false, facecapOrient: true) {
            NSLog("GrokAvatar HeadRig: loaded facecap morphs=%d", morphNodes.count)
            return
        }
        let fb = HeadRigFallback()
        fallback = fb
        root.addChildNode(fb.root)
    }

    private func resourceURL(name: String, ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        let path = ("~/GrokAvatar/Models/\(name).\(ext)" as NSString).expandingTildeInPath
        let dev = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func image(_ name: String) -> NSImage? {
        guard let url = resourceURL(name: name, ext: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    @discardableResult
    private func loadUSDZ(name: String, preferEmbeddedMaterials: Bool, facecapOrient: Bool) -> Bool {
        guard let url = resourceURL(name: name, ext: "usdz") else { return false }
        do {
            let scene = try SCNScene(url: url, options: [
                .checkConsistency: true,
                .convertUnitsToMeters: true
            ])
            let container = SCNNode()
            // Orient on a child so boundingBox includes rotation (parent bbox ignores own euler).
            let orient = SCNNode()
            if facecapOrient {
                orient.eulerAngles = SCNVector3(CGFloat.pi / 2, CGFloat.pi, 0)
            } else if name == "tifa_animated" {
                // Head-only USDZ faces -Z in SceneKit; yaw 180 so face looks at camera (+Z).
                orient.eulerAngles = SCNVector3(0, -CGFloat.pi / 2, 0)
            } else {
                orient.eulerAngles = SCNVector3(0, 0, 0)
            }
            for child in Array(scene.rootNode.childNodes) {
                orient.addChildNode(child)
            }
            container.addChildNode(orient)

            let (minVec, maxVec) = container.boundingBox
            let size = SCNVector3(maxVec.x - minVec.x, maxVec.y - minVec.y, maxVec.z - minVec.z)
            let maxDim = max(size.x, max(size.y, size.z))
            // Head-only mesh: center whole head in view (no Y bias — bias was clipping the mouth).
            let headOnly = preferEmbeddedMaterials
            let target: CGFloat = headOnly ? 1.05 : 1.25
            let scale = maxDim > 0 ? target / CGFloat(maxDim) : 1.0
            container.scale = SCNVector3(scale, scale, scale)
            let cx = (minVec.x + maxVec.x) * 0.5
            let cy = (minVec.y + maxVec.y) * 0.5
            let cz = (minVec.z + maxVec.z) * 0.5
            container.position = SCNVector3(-cx * scale, -cy * scale, -cz * scale)
            NSLog("GrokAvatar frame headOnly=%d maxDim=%.3f scale=%.3f y=%.3f..%.3f",
                  headOnly ? 1 : 0, Double(maxDim), Double(scale), Double(minVec.y), Double(maxVec.y))

            if preferEmbeddedMaterials {
                polishEmbeddedMaterials(in: container)
            } else {
                applyFacecapMaterials(in: container)
            }

            root.addChildNode(container)
            modelContainer = container
            morphNodes.removeAll()
            nameToIndex.removeAll()
            discoverMorphers(in: container)
            mapMorphNames()

            if morphNodes.isEmpty {
                usesProceduralMouth = true
                installProceduralMouth(relativeTo: container, minVec: minVec, maxVec: maxVec, scale: scale)
            } else {
                usesProceduralMouth = false
            }
            return true
        } catch {
            NSLog("GrokAvatar HeadRig USDZ error (%@): %@", name, error.localizedDescription)
            return false
        }
    }

    private func mapMorphNames() {
        nameToIndex.removeAll()
        guard let (_, morpher) = morphNodes.first else { return }
        for (i, target) in morpher.targets.enumerated() {
            let n = (target.name ?? "").trimmingCharacters(in: .whitespaces)
            if !n.isEmpty {
                nameToIndex[n] = i
                // aliases
                let low = n.lowercased()
                if low == "blink" {
                    nameToIndex["eyeBlink_L"] = i
                    nameToIndex["eyeBlink_R"] = i
                }
                if low == "jaw" || low == "jawopen" {
                    nameToIndex["jaw"] = i
                    nameToIndex["jawOpen"] = i
                }
                if low == "eyelookleft" { nameToIndex["eyeLookLeft"] = i; nameToIndex["eyeLookOut_L"] = i; nameToIndex["eyeLookIn_R"] = i }
                if low == "eyelookright" { nameToIndex["eyeLookRight"] = i; nameToIndex["eyeLookOut_R"] = i; nameToIndex["eyeLookIn_L"] = i }
                if low == "eyelookup" { nameToIndex["eyeLookUp"] = i; nameToIndex["eyeLookUp_L"] = i; nameToIndex["eyeLookUp_R"] = i }
                if low == "eyelookdown" { nameToIndex["eyeLookDown"] = i; nameToIndex["eyeLookDown_L"] = i; nameToIndex["eyeLookDown_R"] = i }
            }
        }
        // facecap-style fallback by knownOrder if unnamed
        if nameToIndex.isEmpty {
            let count = morpher.targets.count
            for (i, name) in knownOrder.prefix(count).enumerated() {
                nameToIndex[name] = i
            }
        }
        NSLog("GrokAvatar HeadRig morph map: %@", nameToIndex.keys.sorted().joined(separator: ","))
    }

    /// Loop skeletal / baked idle animations found on the hierarchy.
    func playIdleAnimations() {
        // Body/bone idle intentionally skipped — lips + eyes only.
        idlePlaying = true
        NSLog("GrokAvatar HeadRig: skeletal idle skipped (lips/eyes focus)")
    }

    private func installProceduralMouth(relativeTo container: SCNNode, minVec: SCNVector3, maxVec: SCNVector3, scale: CGFloat) {
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(calibratedRed: 0.15, green: 0.02, blue: 0.04, alpha: 1)
        mat.emission.contents = NSColor(calibratedRed: 0.25, green: 0.04, blue: 0.06, alpha: 1)
        mat.emission.intensity = 0.35
        let plane = SCNPlane(width: 0.09, height: 0.02)
        plane.materials = [mat]
        let cue = SCNNode(geometry: plane)
        let localH = (maxVec.y - minVec.y)
        let localD = (maxVec.z - minVec.z)
        cue.position = SCNVector3(0, (minVec.y + localH * 0.72), maxVec.z - localD * 0.08)
        cue.scale = SCNVector3(1 / scale, 1 / scale, 1 / scale)
        cue.opacity = 0
        container.addChildNode(cue)
        mouthCue = cue
    }

    private func polishEmbeddedMaterials(in node: SCNNode) {
        func walk(_ n: SCNNode) {
            if let g = n.geometry {
                for m in g.materials {
                    m.lightingModel = .physicallyBased
                    m.isDoubleSided = false
                    if m.metalness.contents == nil { m.metalness.contents = 0.0 }
                    m.roughness.contents = 0.62
                    m.locksAmbientWithDiffuse = true
                }
            }
            for c in n.childNodes { walk(c) }
        }
        walk(node)
    }

    private func applyFacecapMaterials(in node: SCNNode) {
        let skinImg = image("skin_albedo")
        let eyeImg = image("eye_albedo")
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = skinImg ?? NSColor(calibratedRed: 0.91, green: 0.74, blue: 0.64, alpha: 1)
        skin.metalness.contents = 0.0
        skin.roughness.contents = 0.42
        let eyeWhite = SCNMaterial()
        eyeWhite.lightingModel = .physicallyBased
        eyeWhite.diffuse.contents = eyeImg ?? NSColor(calibratedWhite: 0.95, alpha: 1)
        func walk(_ n: SCNNode) {
            let name = (n.name ?? "").lowercased()
            if let g = n.geometry {
                if name.contains("mesh_0") || name.contains("eye") { g.materials = [eyeWhite] }
                else if name.contains("mesh_2") || name.contains("head") || g.materials.isEmpty { g.materials = [skin] }
                else {
                    for m in g.materials {
                        m.lightingModel = .physicallyBased
                        m.metalness.contents = 0.0
                    }
                }
            }
            for c in n.childNodes { walk(c) }
        }
        walk(node)
    }

    private func discoverMorphers(in node: SCNNode) {
        if let morpher = node.morpher, !morpher.targets.isEmpty {
            morphNodes.append((node, morpher))
        }
        for child in node.childNodes { discoverMorphers(in: child) }
    }

    func apply(_ w: LipSyncEngine.Weights, gaze: Gaze = Gaze(), idle: IdleExtras = IdleExtras()) {
        if let fallback {
            fallback.apply(w)
            return
        }

        if usesProceduralMouth, let cue = mouthCue {
            let open = max(0, min(1, w.jawOpen))
            cue.opacity = CGFloat(min(1, open * 1.6))
            cue.scale.y = CGFloat(0.35 + open * 3.2)
            cue.scale.x = CGFloat(0.85 + open * 0.35)
        }

        guard !morphNodes.isEmpty else { return }

        // Smooth jaw for more natural lip motion (attack faster than release)
        let targetJaw = max(0, min(1, w.jawOpen))
        let jawLerp: Float = targetJaw > smoothedJaw ? 0.45 : 0.22
        smoothedJaw += (targetJaw - smoothedJaw) * jawLerp

        var values: [String: Float] = [:]
        values["jaw"] = smoothedJaw
        values["jawOpen"] = smoothedJaw
        // Breath minimized (lips/eyes focus)
        values["breath"] = 0  // body morph disabled — lips/eyes only
        let blinkW = max(w.eyeBlink, idle.blink)
        values["blink"] = blinkW
        values["eyeBlink_L"] = blinkW
        values["eyeBlink_R"] = blinkW

        // Eyes follow face-tracking gaze
        let lx = max(-1, min(1, gaze.lookX))
        let ly = max(-1, min(1, gaze.lookY))
        values["eyeLookLeft"] = max(0, -lx)
        values["eyeLookRight"] = max(0, lx)
        values["eyeLookUp"] = max(0, ly)
        values["eyeLookDown"] = max(0, -ly)
        // ARKit aliases if present
        values["eyeLookOut_L"] = max(0, lx) * 0.85
        values["eyeLookIn_R"] = max(0, lx) * 0.85
        values["eyeLookIn_L"] = max(0, -lx) * 0.85
        values["eyeLookOut_R"] = max(0, -lx) * 0.85
        values["eyeLookUp_L"] = max(0, ly) * 0.85
        values["eyeLookUp_R"] = max(0, ly) * 0.85
        values["eyeLookDown_L"] = max(0, -ly) * 0.85
        values["eyeLookDown_R"] = max(0, -ly) * 0.85

        // Only lips/eyes morphs — never drive breath or unknown targets.
        let allowed: Set<String> = [
            "jaw", "jawOpen", "blink",
            "eyeLookLeft", "eyeLookRight", "eyeLookUp", "eyeLookDown",
            "eyeBlink_L", "eyeBlink_R",
            "eyeLookIn_L", "eyeLookIn_R", "eyeLookOut_L", "eyeLookOut_R",
            "eyeLookUp_L", "eyeLookUp_R", "eyeLookDown_L", "eyeLookDown_R"
        ]
        for (_, morpher) in morphNodes {
            let n = morpher.targets.count
            for i in 0..<n { morpher.setWeight(0, forTargetAt: i) }
            for (name, weight) in values {
                guard allowed.contains(name), let idx = nameToIndex[name] else { continue }
                morpher.setWeight(CGFloat(max(0, min(1, weight))), forTargetAt: idx)
            }
        }
    }
}

final class HeadRigFallback {
    let root = SCNNode()
    private let jaw = SCNNode()
    private let jawMaxAngle: Float = 0.55
    init() {
        let skin = SCNMaterial()
        skin.diffuse.contents = NSColor(calibratedRed: 0.91, green: 0.74, blue: 0.65, alpha: 1)
        skin.lightingModel = .physicallyBased
        let skull = SCNNode(geometry: { let g = SCNSphere(radius: 0.45); g.materials = [skin]; return g }())
        skull.position = SCNVector3(0, 0.15, 0)
        root.addChildNode(skull)
        jaw.position = SCNVector3(0, -0.05, 0.1)
        root.addChildNode(jaw)
    }
    func apply(_ w: LipSyncEngine.Weights) {
        jaw.eulerAngles.x = CGFloat(jawMaxAngle) * CGFloat(w.jawOpen)
    }
}
