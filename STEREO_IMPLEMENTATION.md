# Stereoscopic Depth on Apple Vision Pro — Implementation

How Dusklight renders genuine **per-eye stereoscopic 3D** of *Twilight Princess* on Apple Vision Pro,
end to end: the architecture, the render pipeline, every file/function that matters, and *why* each
piece exists. Companion to `STEREO.md` (the original design doc) and `HANDOFF.md` (build/run state).

> Status: per-eye stereo renders and **fuses** on real AVP hardware. The **default presentation is a
> world-locked screen** (comfortable, no camera-fighting); **judder is fixed and head-lean parallax works**
> after adopting reverse-Z depth + a single shared device anchor (§12). The original **face-locked panel**
> and an optional **head-look** (head drives TP's camera) are preserved as alternate, build-selected modes.
> See "Presentation modes" immediately below; §12–§13 cover how the present works, decisions, and next
> steps. visionOS-only — every change is guarded so other platforms are byte-for-byte unaffected.

---

## Presentation modes & how to build each (READ FIRST)

After the per-eye stereo first fused, the port gained a second presentation and a head-look experiment.
There are now **two presentation modes** (plus a head-look sub-option), selected by config. Switching is
**build-time**: change the default in `src/dusk/settings.cpp` and rebuild — there is no on-device toggle
(by design). The engine reads the config and mirrors it to the present thread via
`dusk::vision::stereo_set_world_locked()`, because `StereoPresent.mm` (ARC, no game PCH) cannot include
`settings.h` (it would pull `dolphin/types.h`'s `bool` typedef + `global.h` constants into the TU).

| Mode | `visionWorldLockedScreen` | `visionHeadLook` | What you get |
|------|---------------------------|------------------|--------------|
| **World-locked screen** *(default)* | `true` | `false` | Stereo frame on a screen **fixed in your room**, compositor-reprojected from your live head pose at 90 Hz. Comfortable; TP's camera untouched. You look *at/around* a floating screen. (§10) |
| **Face-locked panel** | `false` | `false` | Legacy panel: the stereo frame **fills your view**, glued to your head — bigger, more immersive. |
| **Face-locked + head-look** | `false` | `true` | As above, but your head **drives TP's camera** (look around *in* the game). ⚠ Motion fighting — see §11. |

**Why a world-locked default?** Driving TP's **30 Hz** game camera from the head under a **90 Hz**
face-locked panel produced a tug-of-war ("fighting") that no camera math fixed — it is architectural
(§11). The world-locked screen sidesteps it (leave the camera alone; let the compositor do the head
tracking), so it is the default. The face-locked path is preserved for immersion/experimentation.

### Building each mode

Full configure/sign/install/disc-push recipe and device IDs: `HANDOFF.md` §8 and `CLAUDE.md` (Apple
Vision section). **Do not reconfigure** CMake — it wipes the throwaway SDL patches; just `cmake --build`.

1. **World-locked screen (default)** — build as-is:
   ```sh
   cmake --build build/visionos-default        # device  (build/visionos-sim-default for the simulator)
   ```
2. **Face-locked panel** — set the screen default `false`, **and** restore the panel-convergence slide
   (it is `0` for the world-locked quad, but the face-locked panel needs it to fuse — §4b), then build:
   ```cpp
   // src/dusk/settings.cpp
   .visionWorldLockedScreen {"game.visionWorldLockedScreen", false},
   // src/dusk/vision/StereoPresent.mm   (~0.25 fused on device; 0 is correct only for world-locked)
   static constexpr float kStereoConvergence = 0.25f;
   ```
3. **Face-locked + head-look** — additionally enable head-look:
   ```cpp
   // src/dusk/settings.cpp
   .visionHeadLook {"game.visionHeadLook", true},
   ```

---

## 1. The core constraint (why this is non-trivial)

Dusklight renders through **Aurora**, whose GX→graphics abstraction runs on **WebGPU/Dawn**, which on
Apple targets lowers to Metal. That indirection is the whole problem:

- Apple's efficient stereo paths — **vertex amplification** and **layered render targets** (one draw,
  two eyes) — are Metal features Dawn does not expose. They are unreachable from Aurora.
- visionOS only vends the immersive render target (`cp_layer_renderer_t`) through a SwiftUI
  `ImmersiveSpace` hosting a `CompositorLayer`. There is no C/UIKit API to get one.

So the realistic approach is: **render the scene twice** (once per eye, each with its own horizontally
shifted projection) into two textures, and **present them ourselves** through CompositorServices. The
glue between Dawn (which produces the frames) and CompositorServices (which displays them) is
**IOSurface**, shared zero-copy between the two.

Two ways to "render twice" were considered (see `STEREO.md` §5):
1. Drive the game's render loop twice — **rejected**: `fapGm_Execute()` runs game *logic* and render
   together; calling it twice double-steps the simulation, and re-running the decomp draw risks state
   side effects.
2. **Aurora command-list replay** — **chosen**: the game renders once (mono); Aurora records the
   frame's GX draws into a replayable command list and **re-encodes them a second time per eye** with a
   per-eye projection patch. The game logic runs once; only GPU work is duplicated. **No WGSL shader
   change** (shaders are shared across all platforms) — the per-eye difference is patched into a
   per-eye *copy* of the uniform buffer.

---

## 2. Architecture

```
                 ENGINE THREAD                          PRESENT THREAD
        (Aurora / Dawn; not thread-safe)        (CompositorServices / Metal)
        ────────────────────────────────        ─────────────────────────────────
  game logic + render (once, mono)
        │                                          runStereoPresentLoop():
        │  m_Do_main.cpp frame loop:                 cp_frame_query_drawables()
        │    stereo_engine_frame_begin() ◄───────────┐ publishEyeSurfaceIfNeeded()
        │    aurora_end_frame()                      │   (alloc 2 BGRA8 IOSurfaces,
        │    stereo_engine_frame_end()               │    sized to the drawable)
        ▼                                            │
  aurora::end_frame() (aurora.cpp):                  │  per drawable:
    gfx::render()      ── mono into EFB              │    blit g_eye[L] ─► view 0 color
    [mono swapchain present, invisible here]         │    blit g_eye[R] ─► view 1 color
    gfx::render_stereo_eyes():                       │    clear+store drawable DEPTH
      for each eye:                                  │    set device anchor (ARKit)
        replay GX draws w/ patched proj ─► EFB        │    cp_drawable_encode_present()
        resample + per-eye convergence blit          │
            ─► eye IOSurface  ───────────────────────┘  (reads IOSurface via MTLSharedEvent fence)
```

**Two threads, one hard rule.** Aurora's Dawn device is **not thread-safe** and is used only on the
engine thread. So *all* Dawn work — importing the IOSurfaces, opening/closing shared-texture access,
recording the eye replays — happens on the **engine thread**, serialized with Aurora's queue submit.
The **present thread** does only Metal-side work (blit IOSurface→drawable, depth, present) and ARKit
anchor queries. The two communicate through:
- **two IOSurfaces** (`g_eye[0]`/`g_eye[1]`, left/right), allocated by the present thread (it alone
  knows the drawable's per-eye texture size), imported into Dawn by the engine thread;
- **`MTLSharedEvent` fences** (per eye) so the present thread waits for the engine's blit to finish
  before sampling the IOSurface.

**IOSurface ↔ Dawn interop** is the proven spike that everything rests on (`StereoBridge`): a
caller-allocated BGRA8 IOSurface is wrapped as a `wgpu::SharedTextureMemory` + `wgpu::Texture` so
Aurora can render into it, and exposes the same storage as an `MTLTexture` (+ a fence) so the present
loop can read it. `BeginAccess`/`EndAccess` bracket each frame's writes and produce the fence.

---

## 3. The per-frame render pipeline (the important part)

Per frame, inside `aurora::end_frame()` (`extern/aurora/lib/aurora.cpp`):

1. **`gfx::end_frame()`** uploads the frame's vertex/uniform/etc. buffers. Just before unmapping the
   uniform staging buffer, it calls **`upload_stereo_eye_uniforms()`**, which:
   - scans the recorded passes to set **`g_stereoFrameHadGx`** (did this frame draw any GX 3D
     geometry? — false on pure 2D/UI screens like the disc picker);
   - if stereo is armed, makes **two CPU copies** of the uniform bytes and **patches each
     non-orthographic draw's projection** per eye (the parallax math, §4), uploading them to
     **`g_uniformBufferEye[0/1]`**.

2. **`gfx::render()`** replays the recorded command list:
   - When stereo is armed, it **skips the mono replay entirely** (the mono swapchain present is
     invisible inside the immersive space — re-rendering for it is pure waste). Otherwise it renders
     mono into the EFB via **`replay_passes_into_targets(cmd, nullptr, …)`**.
   - It **defers** clearing `g_renderPasses` so the recorded passes survive to the eye replay.

3. The mono swapchain present block runs (resample → RmlUi composite → present to the SDL surface).
   On visionOS this surface isn't what the headset shows, so it's effectively a no-op consumer; it is
   left intact for non-immersive/other paths.

4. **2D-UI frames (no GX): mono fallback.** If stereo is armed but `stereo_frame_had_gx()` is false,
   there's nothing to render per-eye, so the flat composite is blitted into **both** eye IOSurfaces
   (`record_stereo_capture_blit_into`). Menus/disc-select show flat in both eyes.

5. **GX frames: the per-eye render — `gfx::render_stereo_eyes(cmd, viewport)`.** For each eye:
   - **`replay_passes_into_targets(cmd, &g_uniformBindGroupEye[eye], …)`** re-encodes the *same*
     recorded passes into the *real* EFB/offscreen targets, but GX draws bind that eye's patched
     uniform bind group. Because it reproduces the **full multi-pass pipeline** (bloom/glow downsample
     chain, EFB-copy passes, …) into their proper targets, the final pass MSAA-resolves into
     `present_source()` exactly as the mono path does — just with the eye's shifted projection.
   - **`resample_present_source()`** viewport-fits that eye image (the 21:9 / 64:27 letterbox), and
     **`record_stereo_capture_blit_into(... xShiftPx)`** blits it into that eye's IOSurface,
     **aspect-fit (letterboxed) + shifted horizontally by the per-eye convergence** (§4).

6. The present loop (other thread) waits on each eye's fence, blits `g_eye[0]`→view 0 and
   `g_eye[1]`→view 1 (mapping via `logicalEyeForView`), **clears+stores the drawable depth**, attaches
   the device anchor, and `cp_drawable_encode_present`s.

**Why re-render through the real targets instead of straight into the eye texture?** The first
attempt redirected *every* recorded pass into the single eye view. That dumped the offscreen bloom
downsample passes (each at its own shrinking viewport) into the eye, stacked on top of each other —
the infamous "progressively-smaller tiles + stray glow." It also fed MSAA/surface-format pipelines a
single-sample BGRA8 target (latent crash). Routing each eye through the **real** pipeline and then
converting via the **proven mono capture path** (resample + format-converting blit) fixed the tiling,
the scaling, and the format/MSAA mismatch in one move.

---

## 4. The per-eye math (two independent knobs)

Two separate horizontal effects combine to make comfortable stereo. They were tuned on-device by
sweeping (a stepped ladder cycled live so the right value could be picked by eye in one run — see
`STEREO_EYESEP_SWEEP` in `StereoPresent.mm`).

### 4a. Scene parallax — `kStereoEyeSep` (depth-dependent)

Applied in the **projection** (`upload_stereo_eye_uniforms`). The GX vertex shader does
`out.pos = vec4f(mv_pos, 1.0) * ubuf.proj` (`extern/aurora/lib/gx/shader.cpp:923`). WGSL matrices are
**column-major**, so the first four floats of `proj` are **column 0** — which *are* the coefficients
of `clip.x`:

```
clip.x = mv.x*proj[0] + mv.y*proj[1] + mv.z*proj[2] + 1*proj[3]
                ^focalX                                   ^constant (homogeneous) term
```

The patch, per non-orthographic draw, per eye:

```c
proj[3] += -eyeSep * focalX;   // add a CONSTANT to clip.x
```

A constant added to `clip.x` becomes, after the perspective divide (`÷clip.w`, where `clip.w ≈`
depth), a **screen shift that scales with 1/depth** — i.e. genuine parallax: near objects shift a lot,
distant objects barely move (the background fuses near infinity). Left eye gets `-eyeSep`, right gets
`+eyeSep`. `focalX` makes the separation scale with each draw's own focal length. **Orthographic draws
(HUD/2D) are skipped** so the in-game HUD stays on a fixed screen plane.

`eyeSep` is in opaque TP world units; the comfortable value is small (even `1.0` over-diverged on
device — see §8).

### 4b. Panel convergence — `kStereoConvergence` (constant)

Applied as a **per-eye horizontal shift of the whole panel in the blit** (`record_stereo_capture_blit_into`,
driven from `g_stereoEyeTargets.convergence[eye]`, **opposite sign per eye**). This is *not* in the
projection — it slides the finished image left in one eye and right in the other.

**Why it's needed and why it's large (~0.25 NDC).** The AVP's per-eye projections are strongly
**off-axis asymmetric** (the logged `skewX = projection.columns[2].x`). We render a flat panel and
fill the eye frustum with it; because the frustums are asymmetric, "centered in the texture" lands at
different world angles per eye, giving the flat panel a **large built-in disparity** that
`eyeSep` (depth-only) cannot cancel. Sweeping `eyeSep` did *nothing* to this constant offset — the
giveaway that a *constant* convergence knob was the missing piece. Sliding the panels oppositely
(≈0.25 NDC per eye) cancels the asymmetry and the panel fuses.

> **Mode-dependent.** The ≈0.25 slide is for the **face-locked panel** only. In the **world-locked
> screen** (§10, the default) each eye already gets its correct view of the quad via the real per-eye
> transform/projection, so the constant slide is *wrong* there (it pushes the images ~50% apart and edge
> content falls outside one eye). `kStereoConvergence` is therefore **`0`** by default; set it back to
> ≈`0.25f` only when building the face-locked panel.

---

## 5. Files changed — Dusk layer (`src/dusk/vision/`, `src/m_Do/`, platform)

| File | What / why |
|---|---|
| **`src/dusk/vision/StereoPresent.mm`** | The heart of the Dusk side. The CompositorServices present loop (`runStereoPresentLoop`), the engine-thread hooks (`stereo_engine_frame_begin/end`), eye-IOSurface allocation (`publishEyeSurfaceIfNeeded`), view→eye mapping (`logicalEyeForView`), the ARKit device-anchor machinery, the per-eye drawable blit + depth, and the **tunables** (`kStereoEyeSep`, `kStereoConvergence`) + the on-device tuning sweep. |
| **`src/dusk/vision/StereoBridge.{h,mm}`** | `SharedEyeTexture` — wraps an IOSurface as a Dawn `SharedTextureMemory`+`Texture` (so Aurora renders into it) and exposes the `MTLTexture` + `MTLSharedEvent` fence (so the present loop reads it safely). `createBGRA8IOSurface`. This is the zero-copy interop that lets two graphics APIs share the frame. |
| **`src/dusk/vision/StereoEngine.h`** | Declares the two engine-thread hooks as plain C++ (no Metal types) so the game TU can call them without pulling in CompositorServices. Documents the engine-vs-present threading rule. |
| **`src/dusk/vision/DuskVisionApp.swift`** | The SwiftUI app: opens the `ImmersiveSpace` and the `CompositorLayer`. `DuskLayerConfiguration: CompositorLayerConfiguration` sets the layer **layout**, **foveation off**, **`.renderTarget` color usage**, and crucially the **`bgra8Unorm` color format** (matching the capture IOSurface — see §7). `.immersionStyle(.full)` is mandatory or the layer is never composited. |
| **`src/m_Do/m_Do_main.cpp`** | Brackets `aurora_end_frame()` with `stereo_engine_frame_begin()` / `stereo_engine_frame_end()` (the per-frame import/access points), and forces `AuroraSetViewportPolicy(AURORA_VIEWPORT_FIT)` for the 21:9 presentation on visionOS. |
| **`src/m_Do/m_Do_graphic.cpp`** | Pins the render (EFB) size to **64:27** on visionOS (`l_tvSize[1].width = height*64/27`), so `present_source` has the intended display aspect ratio that the eye blit then letterboxes. |
| `platforms/visionos/`, `CMakePresets.json`, `CMakeLists.txt`, `src/dusk/file_select.cpp` | The visionOS *port* scaffolding the stereo work sits on (Info.plist, presets, the `TARGET_OS_VISION` gating). Documented in `CLAUDE.md`. |

---

## 6. Files changed — Aurora engine (`extern/aurora/lib/`)

All additive and visionOS-relevant; the mono path is unchanged when stereo isn't armed.

| File | What / why |
|---|---|
| **`lib/gfx/common.cpp`** | The core of the replay. Adds `g_uniformBufferEye[2]`/`g_uniformBindGroupEye[2]` (per-eye uniform copies); `upload_stereo_eye_uniforms` (the per-eye projection patch + `g_stereoFrameHadGx`); **`replay_passes_into_targets`** (factored mono/eye pass-replay into the real targets); reworked **`render`** (skips mono when stereo armed, defers the pass clear); **`render_stereo_eyes`** (per-eye re-render → resample → convergence blit into eye IOSurfaces); `discard_render_passes`; and `render_pass` gains an optional per-eye uniform bind group. |
| **`lib/gfx/common.hpp`** | Declares the above (`render_stereo_eyes`, `discard_render_passes`, `stereo_frame_had_gx`, the `render_pass` eye param). |
| **`lib/webgpu/gpu.{cpp,hpp}`** | `set_stereo_eye_targets` / `has_stereo_eye_targets` + the `StereoEyeTargets g_stereoEyeTargets` struct (per-eye view, size, eyeSep, convergence). **`record_stereo_capture_blit_into`** — the format-converting blit that fills an eye IOSurface, now **aspect-fit (letterbox)** + **per-eye `xShiftPx` convergence**. Uses `present_source()` / `resample_present_source()`. |
| **`lib/aurora.cpp`** | `end_frame` orchestration: after the mono present, the 2D-UI **mono fallback** (no GX → blit composite to both eyes) and the GX **`render_stereo_eyes`** call, plus `discard_render_passes` as the per-frame clear safety net. |
| **`lib/gx/pipeline.{cpp,hpp}`** | `DrawData` gains **`projOffset`** (byte offset of this draw's projection in the uniform buffer) + **`projOrtho`** (skip-if-2D flag). Adds the eye-aware **`gx::render(data, pass, uniformBindGroup)`** overload that binds the per-eye bind group at slot 1. |
| **`lib/gx/shader_info.{cpp,hpp}`** | `build_uniform` records the projection's byte offset (so the patch knows where to write). |
| **`lib/gx/command_processor.cpp`** | Populates `projOffset` (absolute uniform offset) and `projOrtho` (`projType == GX_ORTHOGRAPHIC`) when recording each draw. |
| `tests/gx_test_stubs.cpp` | Tracks the `build_uniform` signature change. |

---

## 7. Key functions, at a glance

- **`render_stereo_eyes` / `replay_passes_into_targets`** (`gfx/common.cpp`) — the actual per-eye
  rendering. If you change how eyes are produced, it's here.
- **`upload_stereo_eye_uniforms`** (`gfx/common.cpp`) — the parallax (`eyeSep`) math. Owns
  `g_stereoFrameHadGx`.
- **`record_stereo_capture_blit_into`** (`webgpu/gpu.cpp`) — letterbox + convergence (`xShiftPx`).
  Owns how an eye image lands in its IOSurface; the panel-fusion knob lives here.
- **`set_stereo_eye_targets` / `g_stereoEyeTargets`** (`webgpu/gpu.cpp`) — the engine→Aurora handoff of
  per-eye views + tunables, re-set every frame (which is what makes the live tuning sweep work).
- **`stereo_engine_frame_begin/end`** (`StereoPresent.mm`) — the one-time Dawn import + per-frame
  `BeginAccess`/`EndAccess`; also where the tuning sweep sets per-frame `eyeSep`/`convergence`.
- **`runStereoPresentLoop` + per-frame present** (`StereoPresent.mm`) — drawable query, eye→view blit,
  **depth write**, device anchor, `encode_present`.
- **`SharedEyeTexture`** (`StereoBridge.mm`) — IOSurface↔Dawn↔Metal, with the cross-thread fence.

---

## 8. Tunables & on-device findings

In `StereoPresent.mm`:

```c
static constexpr float kStereoEyeSep      = 0.5f;   // scene depth parallax (game units)
static constexpr float kStereoConvergence = 0.25f;  // per-eye NDC panel shift (opposite per eye)
#define STEREO_EYESEP_SWEEP 0                        // 1 = live tuning sweep in stereo_engine_frame_begin
```

- **Convergence ≈ 0.25 NDC** fuses the flat panel (found by sweep). It is large because the AVP
  projection is strongly off-axis (§4b). Applied **opposite per eye** (left `+`, right `−`) — applying
  it with the *same* sign to both eyes (the original bug) has no relative effect.
- **`eyeSep` is small** — even `1.0` over-diverged; the comfortable value is well under that and is
  being finalized. The world-unit→disparity scale is large because the TP camera often sits close to
  geometry (near objects dominate the parallax budget).
- The **sweep** (`STEREO_EYESEP_SWEEP 1`) cycles a value through a stepped ladder (~3–4 s per stable
  step, looping) and logs it, so a comfortable value is found by eye in **one** device build instead of
  one-guess-per-build. Set the toggle back to `0` and bake the chosen constants once dialed in.

---

## 9. Critical gotchas (all device-only; the simulator hides them)

These cost the most time and are the reason "it worked in the sim" wasn't enough:

1. **Depth must be written *and stored* every frame.** The compositor reprojects each frame using its
   depth texture; a frame whose drawable depth wasn't produced **scans out pure black** on device. Fix:
   attach `cp_drawable_get_depth_texture` with `loadAction=Clear, storeAction=Store`. (This was *the*
   black-screen root cause; layout was a red herring.)
2. **Color format must match the IOSurface** (BGRA8). The drawable defaults to `RGBA16Float`; blitting
   the BGRA8 capture into it cross-format gives a magenta tint + channel fringing. The AVP immersive
   layer offers `bgra8Unorm_srgb` — use it.
3. **Every presented drawable needs a tracked device anchor**, or the compositor drops it (you see
   nothing, no crash). Keep all ARKit objects as process-lifetime statics; start the session on the
   main thread; always `encode_present` regardless (never gate present on the anchor).
4. **`.immersionStyle(.full)`** is required or the `CompositorLayer` is never composited.
5. Use the **`cp_frame_query_drawables` array API** (visionOS 26) + the frame-timing handshake; the
   deprecated single-drawable API aborts `BUG IN CLIENT` on device.
6. **`TARGET_OS_IOS == 0` on visionOS** (`TARGET_OS_VISION`/`IPHONE` are 1). In-source `#if
   TARGET_OS_IOS` paths do *not* activate — gate visionOS explicitly.
7. **Projection layout is column-major** (§4a). The clip.x coefficients are the first four floats
   (column 0); patch `proj[3]` for the constant shift, not the "m0.w" you'd expect from row-major
   intuition.

---

## 10. World-locked screen mode (the default)

Instead of blitting the eye textures fullscreen (a panel glued to your face), this mode draws each eye's
texture onto a **quad fixed in the room**. Each eye renders that quad through its real CompositorServices
transform + projection, so the screen stays put as you move/turn; the compositor reprojects it from the
live head pose at 90 Hz. Result: a stable floating screen — comfortable, and TP's camera is untouched.

Implemented inline in `presentStereoFrame` (the default branch). **Per-eye MVP**:

```
MVP = projection · inverse(originFromDevice · eyeTransform) · panelModel
```

- `projection = cp_drawable_compute_projection(drawable, right_up_back, viewIndex)`.
- `eyeTransform = cp_view_get_transform(view)` is eye→device, so `inverse(originFromDevice · eyeTransform)`
  is the world→eye view matrix — Apple's documented CompositorServices pattern.
- `originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(<this frame's tracked anchor>)`,
  queried once per frame (`currentFramePose`).
- `panelModel` places a unit quad at `kPanelDistance` (2 m) ahead of the **recenter pose** (the first
  tracked head pose), **leveled to gravity** (world up, so a head tilt at anchor time doesn't cant the
  screen), facing the user, scaled to `kPanelHalfW` × `kPanelHalfH` (64:27).

The quad **writes per-eye depth in reverse-Z** (cleared to `0.0` = far, `GreaterEqual`, stored) — the
compositor consumes that depth for its **depth-based positional/parallax reprojection** as the head moves
(and it satisfies the "write depth or scan out black" device rule, §9). Submitting standard-Z (clear `1.0`
/ `LessEqual`) made the compositor mis-read the depth → **no head-translation parallax and judder**;
reverse-Z is the fix. Color is the eye texture sampled and written to the sRGB drawable (sRGB gotcha, §9).
The legacy fullscreen blit is preserved as `renderFaceLockedPanel()` (selected when
`visionWorldLockedScreen` is false).

**Single shared device anchor (critical).** The pose used to build the MVP and the anchor set on the
drawable via `cp_drawable_set_device_anchor` MUST be the *same* `ar_device_anchor` object: query it once
(`currentFramePose` returns both the pose and the anchor; the present loop sets that exact object). Two
separate presentation-time queries diverge during head motion, so the compositor reprojects from a pose
the quad was not rendered for and the frame **shears at the screen edges**. See §12 for the full contract.

**Tunables** (`StereoPresent.mm`): `kPanelDistance`, `kPanelHalfW`, `kPanelHalfH`. The screen anchors
where you face when it first appears (no recenter button yet — a controller-bound recenter is a possible
follow-up). Panel convergence (§4b) must be **0** here: the quad already gives each eye its correct view,
so a constant per-eye slide just breaks fusion / pushes edge content out of one eye.

## 11. Head-look — and why it is off by default

Head-look (`src/dusk/vision/HeadLook.{h,cpp}`, gated on `game.visionHeadLook`) feeds the AVP head pose
into TP's camera so your head turns the in-game view. It composes onto the view matrix at the camera
chokepoints (`d_camera.cpp::camera_draw` and `frame_interpolation.cpp::begin_presentation_camera`) using
the **full relative head-view matrix** — `inverse(rel)` mapped directly, since TP's view space matches
ARKit's right-handed X-right/Y-up/Z-back convention (per `mDoMtx_lookAt`), so it is correct at *any* head
orientation (an earlier yaw/pitch decomposition reversed past ~90°). It is 6DoF (rotation + translation)
and suppressed during cutscenes / Z-lock-on.

**It is disabled by default** because on the **face-locked** panel it "fights": TP's camera updates at
~30 Hz while the panel tracks your head at 90 Hz, so the panel follows your head instantly while the
content swings a frame behind → a tug-of-war that feels like the world shoving back on every movement.
This is **architectural**, not a tuning bug — it survived 3DoF→6DoF, the yaw/pitch→full-matrix rewrite, a
base-camera freeze, and compositor reprojection (each "fixed" one symptom and surfaced another). The
world-locked screen (§10) is the real fix: don't move the game camera at all; let the compositor do the
head tracking. Head-look is kept for the face-locked mode and experimentation — enable with
`visionWorldLockedScreen=false` **and** `visionHeadLook=true`, then rebuild.

## 12. How the visionOS present works — the CompositorServices reprojection contract

The world-locked screen is driven by **two threads** and a strict per-frame contract with the compositor.
Getting any part of the contract wrong shows up as judder, missing parallax, an edge seam, or a black
screen — every symptom this port hit traced back to one of these rules.

**Two threads** (`StereoEngine.h` declares the engine-side hooks; `StereoPresent.mm` runs the present):
- **Engine thread** (the game loop, `m_Do_main.cpp`): runs Aurora/Dawn + the GameCube game, renders the
  mono frame, and Aurora re-renders it per-eye into the two eye IOSurfaces (§3). It also mirrors the
  presentation mode to the present thread (`stereo_set_world_locked`) and latches the head pose.
- **Present thread** (`runStereoPresentLoop` → `presentStereoFrame`): owns CompositorServices + Metal +
  the ARKit device-anchor query, composites the eye textures onto the world-locked quad, and presents.
- They hand the eye textures across via IOSurface + an `MTLSharedEvent` fence (`StereoBridge`), and the
  head anchor across via `g_anchorMutex` / `g_latestQueriedAnchor`.

**The per-frame present loop** (`presentStereoFrame`) follows Apple's canonical CompositorServices
sequence (verified against WWDC23 §10089 / WWDC24 §10092 "Render Metal with passthrough" + metal-by-example):
1. `cp_layer_renderer_query_next_frame`
2. `cp_frame_start_update` / `cp_frame_end_update` (pose-independent work)
3. `cp_frame_predict_timing` → `cp_time_wait_until(cp_frame_timing_get_optimal_input_time(...))`
4. `cp_frame_start_submission` → `cp_frame_query_drawables`
5. query the device anchor at the **drawable's presentation time**
   (`cp_drawable_get_frame_timing` → `cp_frame_timing_get_presentation_time` →
   `ar_world_tracking_provider_query_device_anchor_at_timestamp`)
6. render each eye's quad with the MVP (§10), set that **same** anchor on the drawable, `cp_drawable_encode_present`
7. `[commandBuffer commit]` → `cp_frame_end_submission`

**The three reprojection-correctness rules** (each was a real bug here):
1. **Render at the predicted presentation-time pose AND set that exact anchor** — both, consistently. The
   compositor then reprojects only the residual predicted-vs-actual delta. Parallax comes from BOTH the
   per-frame re-render and the compositor's depth reprojection — never the anchor alone.
2. **One shared anchor** for the MVP and `cp_drawable_set_device_anchor` (§10). Two queries diverge → shear.
3. **Reverse-Z depth**, cleared to `0.0`, stored, correct per-pixel perspective depth — the compositor uses
   it for positional/parallax reprojection (§10). Constant / standard-Z / unstored depth → no parallax.

**What the compositor does NOT do** (adversarially verified): it does **not** synthesize 6DoF parallax from
the anchor alone, and depth reprojection is an image-space correction that cannot reveal disoccluded
geometry. So the app must keep re-rendering each frame from a fresh predicted pose; the compositor only
refines between frames. No motion-vector / velocity submission API exists on `cp_drawable`.

### Key present-thread functions (`src/dusk/vision/StereoPresent.mm`)
- `runStereoPresentLoop` / `presentStereoFrame` — the present loop + the canonical frame sequence above.
- `currentFramePose(drawable, &pose, &anchor)` — single device-anchor query at presentation time; returns
  both the `originFromDevice` matrix (for the MVP) and the anchor object (to set on the drawable).
- `ensurePanelPipeline` — lazily builds the textured-quad pipeline + the **reverse-Z** depth-stencil state.
- `renderFaceLockedPanel` — the legacy fullscreen blit (face-locked mode).
- `stereo_set_world_locked` — engine→present mode mirror (the present TU can't include `settings.h` —
  it would pull `dolphin/types.h`'s `bool` typedef into the ARC/no-PCH unit).
- `attachDeviceAnchor` — now used only by the pre-tracking / force-clear early-return paths.
- `logicalEyeForView` — maps a drawable view to the left/right eye source by its eye-offset sign.
- Engine-thread hooks (`StereoEngine.h`): `stereo_engine_frame_begin/end` (arm/flush the shared eye
  capture), `stereo_engine_latch_head_pose` (snapshot the anchor for head-look).

## 13. Decisions, current state & next steps

### Key decisions
- **Pivoted from head-look to a world-locked screen as the default.** Driving TP's 30 Hz camera from the
  head under a 90 Hz face-locked panel "fought" fundamentally (it survived ~5 fixes — see §11). The
  world-locked screen leaves the game camera untouched and lets the compositor do the head tracking —
  comfortable, no fighting. Head-look is preserved behind config for the face-locked mode.
- **Both presentations kept, switched by `game.visionWorldLockedScreen` (default `true`); rebuild to swap**
  (§"Presentation modes"). No on-device toggle (user's choice).
- **Reverse-Z depth + single shared anchor** were the two fixes (from deep, adversarially-verified web
  research of Apple's CompositorServices docs/WWDC) that resolved the residual judder and missing parallax.

### Current state (works on a real Apple Vision Pro)
World-locked stereo screen: per-eye stereo, world-locked, **judder fixed**, head-lean **parallax working**
(subtle at 2 m — verify by leaning ≥30 cm laterally / approaching the screen, or temporarily set
`kPanelDistance` ≈ 0.7 m to exaggerate it). Colors correct, L/R fuse, edges stable, head-look off.

### Files touched (this visionOS present work)
- `src/dusk/vision/StereoPresent.mm` — world-locked quad render, dual-mode dispatch, present loop,
  reverse-Z depth, single shared anchor, `ensurePanelPipeline`, `currentFramePose`, `renderFaceLockedPanel`.
- `src/dusk/vision/StereoBridge.mm` — eye IOSurface imported as **`BGRA8Unorm_sRGB`** (color round-trip).
- `src/dusk/vision/StereoEngine.h` — `stereo_set_world_locked` + the engine hooks.
- `src/dusk/vision/HeadLook.{h,cpp}` — full-matrix head-look; gated off in world-locked mode.
- `include/dusk/settings.h` + `src/dusk/settings.cpp` — `game.visionWorldLockedScreen` (default `true`),
  `game.visionHeadLook` (default `false`).
- `src/m_Do/m_Do_main.cpp` — mirrors the mode to the present thread; latches the head pose.
- (engine) `extern/aurora/lib/{gfx,webgpu}` — per-eye stereo replay (§6).

### Next steps / open questions
- **Verify parallax magnitude** (lean test / closer `kPanelDistance`); pick a comfortable distance/size.
- **Residual judder under 30 Hz content / 90 Hz present**: the research left the exact pacing for
  low-update content *unsettled* — does a world-fixed screen need a re-encoded drawable every display
  frame even when the game frame is unchanged? Investigate decoupling the present (90 Hz) from the 30 Hz game.
- **Recenter control**: a controller-bound recenter so the screen can be repositioned on-device (it
  currently anchors where you face at launch).
- **Optional transparent background** (alpha 0 + zero depth on non-quad pixels) if mixing with passthrough
  rather than full immersion.
- **Foveation**: query + apply `cp_drawable_get_rasterization_rate_map` (currently ignored — minor artifacts).
- **Per-eye in-screen stereo** (`kStereoEyeSep`) tuning + a disparity clamp; per-eye Dusk UI (RmlUi/ImGui)
  overlay compositing (currently only the GX scene + GX HUD are per-eye).
- **Mid-frame teardown**: keep bailing cleanly if the layer is invalidated (headset off) mid-frame
  (`cp_frame_end_submission` `BUG IN CLIENT`).
- Everything is visionOS-guarded; other platforms are byte-for-byte unaffected.

Build / sign / install / disc-push recipe and device IDs: see **`HANDOFF.md`** §8. Restore-point tags on
`personal` (stacklikemind/dusklight): `visionos-world-locked-screen`, `visionos-stereo-reprojection-fix`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
