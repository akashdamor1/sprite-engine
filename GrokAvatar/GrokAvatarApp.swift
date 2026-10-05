import SwiftUI
import AppKit

@main
struct GrokAvatarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let positionKey = "GrokAvatar.windowFrame"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            Self.style(window)
            Self.restorePosition(window)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows {
            Self.style(window)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let window = NSApp.windows.first {
            Self.savePosition(window)
        }
    }

    static func style(_ window: NSWindow) {
        window.styleMask = [.borderless, .fullSizeContentView, .resizable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        window.hasShadow = true
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 380, height: 460)
        window.maxSize = NSSize(width: 900, height: 1100)
    }

    static func restorePosition(_ window: NSWindow) {
        if let s = UserDefaults.standard.string(forKey: positionKey) {
            let parts = s.split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 {
                var frame = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                // Clamp to visible screen
                if let screen = NSScreen.main {
                    let vis = screen.visibleFrame
                    if !vis.intersects(frame) {
                        frame.origin = NSPoint(
                            x: vis.midX - frame.width / 2,
                            y: vis.midY - frame.height / 2
                        )
                    }
                }
                window.setFrame(frame, display: true)
                return
            }
        }
        // Default: center-ish
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let size = NSSize(width: 520, height: 640)
            let origin = NSPoint(
                x: vis.midX - size.width / 2,
                y: vis.midY - size.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    static func savePosition(_ window: NSWindow) {
        let f = window.frame
        let s = "\(f.origin.x),\(f.origin.y),\(f.size.width),\(f.size.height)"
        UserDefaults.standard.set(s, forKey: positionKey)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                AppDelegate.style(window)
                AppDelegate.restorePosition(window)
                // Persist on move/resize
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { note in
                    if let w = note.object as? NSWindow { AppDelegate.savePosition(w) }
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { note in
                    if let w = note.object as? NSWindow { AppDelegate.savePosition(w) }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                AppDelegate.style(window)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = LipSyncEngine()
    @StateObject private var faceTracker = FaceTracker()
    @State private var cameraOn = true
    @State private var lipSyncOn = true

    var body: some View {
        ZStack(alignment: .bottom) {
            AnimeFaceView(engine: engine, faceTracker: faceTracker)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 0) {
                // Compact control strip
                HStack(spacing: 14) {
                    Toggle(isOn: $cameraOn) {
                        Text("Camera")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: cameraOn) { on in
                        if on { faceTracker.start() } else { faceTracker.stop() }
                    }

                    Toggle(isOn: $lipSyncOn) {
                        Text("Lip sync")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: lipSyncOn) { on in
                        engine.lipSyncEnabled = on
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7, height: 7)
                            .padding(.top, 3)
                        Text(engine.statusNote)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f ms", engine.latencyMs))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    HStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(Color.green.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(min(1, engine.rawRms * 8)))
                            }
                        }
                        .frame(width: 70, height: 5)
                        Text(String(format: "rms %.4f · pkts %d · jaw %.2f",
                                    engine.rawRms, engine.packetCount, engine.weights.jawOpen))
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 0)
                    }
                    Text(camStatus)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.5))
            }
        }
        .frame(minWidth: 400, idealWidth: 520, minHeight: 520, idealHeight: 640)
        .onAppear {
            engine.lipSyncEnabled = lipSyncOn
            engine.start()
            if cameraOn { faceTracker.start() }
        }
        .onDisappear {
            engine.stop()
            faceTracker.stop()
        }
    }

    private var camStatus: String {
        if !cameraOn { return "cam off" }
        if !faceTracker.cameraAuthorized {
            if faceTracker.statusNote.contains("denied") { return "cam denied" }
            return faceTracker.statusNote
        }
        if faceTracker.faceDetected {
            return String(format: "cam ok · face y%.2f p%.2f", faceTracker.yaw, faceTracker.pitch)
        }
        return "cam ok · no face"
    }

    private var dotColor: Color {
        if engine.captureOK && engine.audioFlowing { return .green }
        if engine.captureOK { return .yellow }
        return .orange
    }
}
