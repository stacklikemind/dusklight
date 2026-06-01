# Stereoscopic Depth on Apple Vision Pro — Implementation

How Dusklight renders genuine **per-eye stereoscopic 3D** of *Twilight Princess* on Apple Vision Pro,
end to end: the architecture, the render pipeline, every file/function that matters, and *why* each
piece exists. Companion to `STEREO.md` (the original design doc) and `HANDOFF.md` (build/run state).

> Status: per-eye stereo renders and **fuses** on real AVP hardware. Panel convergence is solved;
> the depth-amount (`kStereoEyeSep`) is in final on-device tuning. visionOS-only — every change is
> guarded so other platforms are byte-for-byte unaffected.

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

## 10. Known limitations / next steps

- **Depth amount** (`kStereoEyeSep`) still being finalized; likely also wants a **disparity clamp** so
  near objects can't diverge past fusion regardless of scene depth.
- **In-game Dusk UI overlays** (RmlUi/ImGui) are not re-rendered per eye — only the GX scene + GX HUD
  are. A flat-layer UI composite over both eyes is a follow-up. (The game's own GX HUD *does* appear,
  on a fixed plane.)
- **Convergence shift clips a full-width panel** at large values; once locked, render the panel
  slightly inset (or bake the convergence into the per-eye projection) to avoid edge clipping.
- **Frame pacing**: the per-eye render is ~2× the GPU work; the present/engine loops also need real
  pacing (the OS has killed the app for excessive CPU wakes).
- **Mid-frame teardown**: bail cleanly if the layer is invalidated (headset off) mid-frame
  (`cp_frame_end_submission` `BUG IN CLIENT`).

Build / sign / install / disc-push recipe and device IDs: see **`HANDOFF.md`** §8.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
