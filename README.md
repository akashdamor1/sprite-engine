# GrokAvatar

Floating macOS talking-head prototype. A procedural SceneKit head lip-syncs to **system audio** captured via ScreenCaptureKit (same approach as SimpleLoginApp’s `SystemAudioLevelCapture`).

## Model used

**three.js facecap** with **52 ARKit blendshapes** (`jawOpen`, `mouthSmile_L/R`, `eyeBlink_L/R`, etc.).

- Source GLB: [three.js examples `facecap.glb`](https://github.com/mrdoob/three.js) (r170)
- Converted on-device: gltf-transform (decode meshopt) → strip KTX/basisu texture → Blender 5.2 → `Models/facecap.usdz`
- Driven via SceneKit `SCNMorpher` on `Mesh_2`
- License notes: see `Models/MODEL-LICENSE.md`
- Fallback: procedural head if USDZ missing

## Lip-sync method

1. **Capture**: ScreenCaptureKit audio stream (48 kHz mono PCM), excluding this process.
2. **Analyze** each buffer (`SystemAudioCapture`):
   - RMS via Accelerate `vDSP_rmsqv`
   - Low / mid / high band proxies via one-pole LP filters (time-domain)
3. **Map** (`LipSyncEngine`, ~60 Hz display link):
   - `jawOpen` ∝ smoothed energy (fast attack / slower release)
   - `mouthWidth` from mid vs high balance (mid → wider/smile, high → funnel)
   - Periodic blinks; eye widen on energy spikes
   - Idle: closed mouth + blinks
4. **Apply** (`HeadRig.apply`): jaw pitch, lip scale, eyelid cover

**Audio2Face**: **not used**. NVIDIA Omniverse Audio2Face needs an NVIDIA GPU; this is Apple M2 — cannot run it.

## Permissions

- **Screen Recording** (System Settings → Privacy & Security) — required for system-audio capture via ScreenCaptureKit.
- No microphone is used.

## Build & run

```bash
cd ~/GrokAvatar
./build-and-run.sh
```

Uses `swiftc` (no Xcode project). Target: `arm64-apple-macosx13.0`.

## Window

- Borderless floating (~320×400), draggable, always-on-top-ish
- Position remembered in `UserDefaults`
- Tiny status strip: capture state + audio-age latency (ms)

## Latency notes

- SCStream audio buffers typically ~10–40 ms
- Envelope attack ~few frames; release slower to avoid chatter
- Status strip shows age of last audio sample vs now (proxy for end-to-end lag)

## 2D VN sprite face (current UI, extra-dense v3 set)

`AnimeFaceView` shows baked visual-novel sprite layers (no runtime Canvas overlays).

- Layers: `Models/sprites/` (182 PNG + `sprite_manifest.json`, about 24 MB). `build-and-run.sh` copies them to `GrokAvatar.app/Contents/Resources/sprites/`.
  - `head_{left3,left2,left1,center,right1,right2,right3}.png`: opaque 1024² head bases (7 yaw steps, 12 px slide per step)
  - `eyes_{H}_{E}.png`: eye-band crops (7×17 = 119)
    - E = center, left1-3 / right1-3 (iris 5/10/15 px), up1-3 / down1-3 (3/6/9 px), blink1/2/3 (lid 22/45/70 %), closed
  - `mouth_{H}_o0..o7.png`: mouth crops, 8 openness tiers (7×8 = 56)
  - The manifest gives each crop's `[x,y,w,h]` on the 1024 canvas.
- Re-bake: `python3 tools/bake_sprites.py Models/anime-face.jpg Models/sprites` (numpy, opencv, scipy, pillow; about 50 s)
- Selection (`SpriteDriver`, 60 Hz, level quantizers with hysteresis):
  - yaw → head, bounds ±0.15/±0.38/±0.62 (hysteresis 0.03)
  - yaw → eye look, ±0.09/±0.24/±0.40
  - pitch → up/down, ±0.12/±0.28/±0.45
  - eyeBlink → blink1/2/3/closed at 0.15/0.38/0.60/0.82
  - jawOpen → o1…o7 at 0.04/0.10/0.16/0.23/0.30/0.38/0.47
  - Head and eye changes crossfade (30 ms for blinks, 50 ms for eye moves, 90 ms for head steps); the mouth snaps.
- Older sets are backed up: v1 in `backup-pre-sprites-v2/sprites_v1`, v2 in `backup-pre-sprites-v3/sprites_v2`.
