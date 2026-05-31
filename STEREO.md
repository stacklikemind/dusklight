# STEREO.md — True Stereoscopic 3D Depth for Dusklight on visionOS

Working design document for implementing genuine per-eye stereoscopic depth (not the flat
"projected 3D movie" look) for Dusklight — the native Twilight Princess port — on Apple Vision Pro.

**Status:** Research + codebase investigation complete. No implementation yet. The next concrete
step is a Dawn↔Metal IOSurface interop spike (see [§7](#7-recommended-next-step-the-interop-spike)).

**Audience:** Dusklight contributors working on the visionOS port. Assumes familiarity with the
existing visionOS build (see `CLAUDE.md` → "Apple Vision (visionOS) port") and the Aurora runtime.

---

## 1. TL;DR

- Dusklight's current visionOS port renders **mono** to a flat `CAMetalLayer` window (21:9). A
  windowed/shared-space surface **physically cannot** produce two per-eye images — true depth is
  impossible on that path.
- The **only** first-party route to genuine per-eye stereo on visionOS is a full `ImmersiveSpace`
  hosting a **CompositorServices** `CompositorLayer` with a custom Metal render loop, which exposes
  the two per-eye view/projection matrices and a layered drawable.
- **Critical constraint:** Aurora is a **WebGPU (Dawn)** renderer, not native Metal. This makes
  Apple's hardware single-pass stereo (**vertex amplification**) and CompositorServices-native
  layered rendering **unreachable from inside Aurora**.
- **Therefore the realistic architecture is:** inject two per-eye projection·view matrices into
  Aurora's uniform path → render the scene **twice** (left/right) into **IOSurface-backed offscreen
  textures** → present them yourself via a CompositorServices `ImmersiveSpace`, blitting each eye
  into `drawable.colorTextures[viewIndex]`.
- This gives **true depth** (real per-eye geometry projection), at ~2× render cost. Vertex
  amplification's savings were vertex-stage only; TP is likely fragment-bound, so the practical loss
  is modest and is mitigated by foveation + dynamic render quality + resolution scaling.
- **Being a native port (not an emulator) is the decisive advantage:** we have the game's actual GX
  projection/view matrices in the render pipeline, so we do real per-eye geometry projection rather
  than framebuffer depth-reprojection hacks.

---

## 2. Background: how visionOS stereo actually works

> Sources verified against Apple primary docs + WWDC sessions (deep-research pass, 25/25 claims
> confirmed, 0 refuted). Citations in [§8](#8-sources).

### 2.1 Architecture — ImmersiveSpace + CompositorServices (high confidence)

- A **windowed / shared-space** Metal render goes through Apple's render server and is composited as
  a single mono image. There is **no per-eye access**. Hard ceiling, not a tuning problem.
- The only first-party path to two per-eye images is a Metal app in a **Full Space** using
  CompositorServices, which *"render[s] drawable frames directly to the Compositor, bypassing the
  render server."*
- Required structure (WWDC2024 session 10092):
  ```swift
  ImmersiveSpace {
    CompositorLayer(configuration: …) { layerRenderer in
      let engine = dusk_vision_engine_create(layerRenderer)   // C/C++ entry into our loop
    }
  }
  ```
- Object mapping (C API used from C++): `CompositorLayer` ↔ `cp_layer`; the per-frame
  `LayerRenderer.Drawable` ↔ `cp_drawable`; each eye ↔ a `cp_view`.
- **A flat textured quad is NOT a substitute.** Drawing the mono frame on a quad in an immersive
  space yields exactly the "projected 3D movie" look. Use the immersive *plumbing* as scaffolding,
  but the eyes must be rendered through real per-eye frusta.

### 2.2 What the drawable provides each frame (high confidence)

Per `cp_drawable`: **two color + two depth textures** (one per eye), **one `cp_view` per eye**
(carrying that eye's transform and frustum tangents), the **rasterization rate maps** (foveation), a
settable **device anchor**, and **timing info** to pace a custom loop up to **90 fps**. The render
loop iterates the drawable's views.

### 2.3 Per-eye view + projection matrices (high confidence — exact recipe)

For each eye/view:
```
view_matrix       = inverse(originFromDevice · deviceFromView)
projection_matrix = asymmetric off-axis frustum from cp_view_get_tangents() + cp_drawable depth range
                    (or equivalently drawable.computeProjection(viewIndex:))
```
- `originFromDevice` ← ARKit `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)`
- `deviceFromView` ← CompositorServices `cp_view_get_transform(view)`
- **IPD / eye separation is already baked in** (`deviceFromView` differs per eye), and
  `cp_view_get_tangents` already encodes each eye's correct **asymmetric convergence frustum**. We do
  not hand-roll IPD — Apple supplies calibrated values.

### 2.4 Head pose & timing (high confidence)

- Head pose: `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)` returns the **predicted** device
  pose at a caller-specified absolute time.
- **Pass the drawable's predicted `presentationTime` (a *future* time, ~33 ms / ~3 frames ahead at
  90 Hz), not `CACurrentMediaTime()`.** This compensates motion-to-photon latency and is precisely
  what kills the "flat movie" feel. Predicting future pose is the intended use in custom
  CompositorServices loops.
- ARKit's `WorldTrackingProvider` requires an `ARKitSession`. As of visionOS 1.0 it is available for
  fully immersive Metal apps.

### 2.5 Foveation, frame pacing, dynamic quality

- **Foveation + pose must be queried per-frame, just-in-time**, immediately before encoding GPU work
  — never cached across frames. Foveation comes from `drawable.rasterizationRateMaps` applied to the
  render pass.
- **Dynamic render quality:** set `configuration.maxRenderQuality` (gated on `isFoveationEnabled`),
  adjust `layerRenderer.renderQuality` at runtime. Apple uses ~0.8 for menus, ~0.6 for world. Higher
  quality = larger texture, more memory + power.
- **Frame pacing (medium confidence — 2-1 vote):** submit exactly one Metal frame per compositor
  update at the display refresh rate — *usually 90 Hz but variable* (can be 96 Hz, etc.). **Do not
  hardcode 90.** Drive cadence from the drawable's timing. This is the central friction porting TP's
  fixed **60 fps** logic onto a 90/96 Hz variable display.

### 2.6 Vertex amplification (the technique we *cannot* use here — see §3)

Metal vertex amplification renders both eyes in one vertex pass: vertex data is fetched once and the
vertex function runs once per amplification ID. Pipeline gets `maxVertexAmplificationCount = 2`
(gated on `supportsVertexAmplificationCount(2)`); encoder calls `setVertexAmplificationCount(2,
viewMappings:)`; the shader reads `uint [[amplification_id]]` to pick the per-eye matrix and outputs
`uint [[render_target_array_index]]` to route each eye into a slice of an `MTLTextureType2DArray`
("layered" layout). **Caveat — not a free 2×:** it saves only the vertex stage; **fragment shading
still runs per eye.** This entire mechanism is **unreachable from Aurora** (see §3).

### 2.7 visionOS 26 / macOS 26 forward-compat (high confidence)

- The loop is moving to `queryDrawables()` returning an **array** of 1–2 drawables (2 only during
  Reality Composer Pro high-quality capture), distinguished by `drawable.target`
  (`.builtIn` / `.capture`). The single-`cp_drawable` model (WWDC2024) remains baseline for
  visionOS 1.x–2.x.
- ARKit + `WorldTrackingProvider` are now on **macOS**: a Mac can query the AVP pose
  (`ARKitSession(remoteDeviceIdentifier:)`, with `cDevice`/`ar_device_t` for C++ interop) and render
  remotely. Relevant only if Dusklight ever offloads rendering to a Mac.

---

## 3. The decisive constraint: Aurora is WebGPU (Dawn), not native Metal

> Investigation of `extern/aurora` (encounter/aurora, submodule pinned at `cb2c340`). Two independent
> code-reading passes agreed. Citations are `file:line` within `extern/aurora/`.

Aurora is **not** a hand-written GX→Metal backend. It is **GX → WGSL → WebGPU (Dawn) → Metal**:

- `BACKEND_METAL` → `wgpu::BackendType::Metal` (`lib/webgpu/gpu.cpp:650`).
- All GPU objects are `wgpu::*` types; all generated shaders are **WGSL strings** that **Dawn**
  transpiles to MSL internally.
- The only Metal-native file in the tree is **`lib/dawn/MetalBinding.mm` (~13 lines)** — it wraps an
  SDL `CAMetalLayer` into a `wgpu::SurfaceSourceMetalLayer`. There is no other `.mm`/Metal code.

**Consequences (these frame everything):**

1. **No vertex amplification.** WGSL/wgpu has no `[[amplification_id]]`,
   `maxVertexAmplificationCount`, `setVertexAmplificationCount`, or `MTLVertexAmplificationViewMapping`.
   Confirmed zero matches in-tree. Apple's hardware single-pass stereo is not expressible without
   forking Dawn.
2. **No layered / array render targets.** `create_render_texture` and `create_depth_texture`
   (`lib/webgpu/gpu.cpp`) hardcode `depthOrArrayLayers = 1`, `dimension = e2D`,
   `viewDimension = e2D`. The EFB (`g_frameBuffer` / `g_frameBufferResolved` / `g_depthBuffer`,
   `gpu.cpp:40-42`) is mono. The render loop (`lib/gfx/common.cpp:761 render()`) uses a single color
   + single depth attachment and one viewport.
3. **Flat `CAMetalLayer` swapchain, no CompositorServices.** One SDL window, one Metal surface; Dawn
   acquires/presents one drawable. No `cp_layer` / drawable-array infrastructure exists. (Matches
   `CLAUDE.md`: the visionOS port "render[s] to a standard `CAMetalLayer` window," flat 21:9.)
4. **`@builtin(instance_index)` — the only WGSL eye-selection candidate — is already consumed** for
   line/point primitive expansion (`lib/gx/shader.cpp:869`). So eye selection cannot piggyback on
   instancing without conflict; use **two separate draws/passes** instead.

---

## 4. What survives, what's blocked

| Element from the visionOS stereo playbook | Status against Aurora | Notes |
|---|---|---|
| CompositorServices `ImmersiveSpace` + custom Metal loop | ✅ Required, built **above/outside** Aurora | Native Swift/Metal layer we add |
| ARKit head pose (`queryDeviceAnchor` at `presentationTime`) | ✅ Feasible | Lives in our present layer |
| Per-eye off-axis frusta from `cp_view_get_tangents` | ✅ Feasible | Feed into matrix injection |
| Per-eye `proj·view` matrix injection into the game render | ✅ **Clean** | See §5 injection points |
| Foveation / `rasterizationRateMaps` | ✅ Feasible | In our present-layer render passes |
| Dynamic render quality (0.6–0.8) + resolution scaling | ✅ Feasible | Primary perf lever |
| **Vertex amplification** (single-pass both eyes) | ❌ **Blocked** | WebGPU has no such primitive |
| **Layered 2D-array render target** | ❌ **Blocked** | Aurora RTs are single 2D, non-layered |
| **CompositorServices-native present from inside Aurora** | ❌ **Blocked** | Aurora presents to flat `CAMetalLayer` |

**Net:** true depth is achievable; hardware single-pass is not. We pay ~2× and present ourselves.

---

## 5. Recommended architecture: two-pass render + self-managed CompositorServices present

The only path that fits Aurora's architecture **and** yields genuine per-eye depth:

1. **Inject two per-eye `proj·view` matrices** into Aurora's uniform path (clean — see §5.1).
2. **Render the scene twice** (left, then right) into **two IOSurface-backed offscreen wgpu
   textures** — reuse the existing `GXCreateFrameBuffer` / `begin_offscreen` machinery.
3. **Present outside Aurora:** stand up a SwiftUI `ImmersiveSpace` + `CompositorLayer`. Each frame,
   wrap those two IOSurfaces as `MTLTexture` and **blit each eye into
   `drawable.colorTextures[viewIndex]`** (one cheap Metal blit per eye), then present the drawable.

### 5.0 The Dawn↔Metal bridge: IOSurface-backed shared textures

The whole plan hinges on getting Aurora's rendered eye images (wgpu textures) into the
CompositorServices drawable (Metal textures). The clean, supported mechanism is **IOSurface**:

- Dawn supports IOSurface-backed shared textures (`wgpu::SharedTextureMemory` with an IOSurface
  descriptor on the Metal backend).
- **Allocate the IOSurfaces once.** Create a wgpu texture from each for Aurora to render an eye into,
  **and** wrap the same IOSurface as an `MTLTexture` for the present loop.
- Per frame, in the CompositorServices loop, Metal-blit each IOSurface-backed `MTLTexture` into the
  drawable's per-eye color texture. Zero-copy sharing between Dawn and our native Metal present.
- ⚠️ **This is the unproven assumption.** Spike it first (see §7) before building anything else.

### 5.1 Concrete injection points (verified `file:line`)

- **`lib/gx/gx.hpp:285`** — `struct GXState`; holds `Mat4x4<float> proj;` (`:294`) and the pos/nrm
  matrices (`pnMtx`, `:292-293`). Add a second projection or an eye index here.
- **`lib/dolphin/gx/GXTransform.cpp:14`** — `GXSetProjection` only writes XF FIFO registers; it does
  not touch GPU state directly.
- **`lib/gx/command_processor.cpp:1416`** — projection is *reconstructed* from the XF FIFO into
  `g_gxState.proj`. `g_gxState.proj` is read nowhere else for rendering, so a per-eye override is
  well contained.
- **`lib/gx/shader_info.cpp:382`** — `build_uniform()` appends `g_gxState.proj` (and pos/nrm/tex
  matrices) into the per-draw uniform block (ring buffer via `gfx::map_uniform`). **This is the place
  to upload two matrices** (or select per pass).
- **`lib/gx/shader.cpp:921`** — the WGSL generator emits:
  ```cpp
  vtxXfrAttrsPre += fmt::format(
      "\n    let mv_pos = vec4f({}, 1.0) * ubuf.postex_mtx[in_pnmtxidx];"
      "\n    out.pos = vec4f(mv_pos, 1.0) * ubuf.proj;", vtx_attr(config, GX_VA_POS));
  ```
  Change the projection multiply to index the chosen eye's matrix. Eye index must come from a
  per-pass uniform (not `instance_index`, which is taken — `shader.cpp:869`).
- **Existing public hooks to lean on** (`include/dolphin/gx/GXAurora.h`): `AuroraSetViewportPolicy`
  (enum `AURORA_VIEWPORT_FIT/STRETCH/NATIVE`), `GXSetViewportRender` / `GXSetScissorRender`,
  `GXCreateFrameBuffer` / `GXRestoreFrameBuffer` (offscreen render targets — the realistic lever for
  per-eye targets). **No** matrix-override or per-eye/RT API exists — we'll add a small one, e.g.
  `AuroraSetProjectionPerEye(const Mat4x4* left, const Mat4x4* right)` or an eye-index setter.

### 5.2 Performance reality

- Vertex amplification only ever saved the **vertex stage**; fragment shading is per-eye regardless.
  TP at AVP resolution is almost certainly **fragment/fill-bound**, so the practical penalty for the
  two-pass approach over amplification is mostly draw-call + vertex-fetch overhead, not the dominant
  cost. Budget ~2× fragment either way.
- Mitigations (all live in our present layer, all still available): **foveation**, **dynamic render
  quality 0.6–0.8**, **render-resolution scaling**.
- **60 → 90/96 Hz pacing:** decouple TP's 60 fps game logic from the variable present rate; Dusk's
  existing frame-interpolation infrastructure is relevant here.

---

## 6. Open questions / tuning knobs

1. **Convergence & world scale.** TP's GX near/far planes are gameplay-tuned, not physical. Need a
   world-units-to-meters scale + convergence offset so the scene isn't miniaturized or hyper-stereo.
   This is now *our* knob in the per-eye matrix injection (§5.1).
2. **2D / HUD / pre-rendered cutscenes.** No real geometry → render on a **fixed-depth stereo plane**
   (same image both eyes at a comfortable convergence distance), kept separate from the genuinely
   stereo 3D world pass.
3. **Does Dawn's IOSurface shared-texture path actually round-trip on visionOS?** The make-or-break
   assumption (§5.0). Spike before committing (§7).
4. **AVP perf budget** for 60 fps TP logic + ~2× stereo render at 90 Hz — can foveation + dynamic
   quality close it, or is reprojection/interpolation needed?

---

## 7. Recommended next step: the interop spike

Before any matrix/two-pass work, prove the architecture with the minimal risky slice:

> **Render one Aurora frame into an IOSurface, wrap it as an `MTLTexture`, and blit it into a
> CompositorServices drawable inside a SwiftUI `ImmersiveSpace`.**

If that round-trips and presents, the rest is "known" engineering (matrix injection, second pass,
per-eye frusta, head pose, foveation). If IOSurface sharing does *not* work, we re-plan (e.g. a
Dawn-level patch or a read-back path) before sinking effort into the matrix work.

*(A detailed step-by-step plan for this spike is the next deliverable.)*

---

## 8. Sources

Apple primary + WWDC (verified, high confidence unless noted):

- Understanding the visionOS render pipeline — https://developer.apple.com/documentation/visionos/understanding-the-visionos-render-pipeline
- Drawing fully immersive content using Metal — https://developer.apple.com/documentation/CompositorServices/drawing-fully-immersive-content-using-metal
- WWDC2024 session 10092 (Render Metal with passthrough / immersive) — https://developer.apple.com/videos/play/wwdc2024/10092/
- WWDC2025 session 294 — https://developer.apple.com/videos/play/wwdc2025/294/
- `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)` — https://developer.apple.com/documentation/arkit/worldtrackingprovider/querydeviceanchor(attimestamp:)
- Improving rendering performance with vertex amplification — https://developer.apple.com/documentation/metal/improving-rendering-performance-with-vertex-amplification
- `MTLVertexAmplificationViewMapping` — https://developer.apple.com/documentation/metal/mtlvertexamplificationviewmapping
- `supportsVertexAmplificationCount` — https://developer.apple.com/documentation/metal/mtldevice/supportsvertexamplificationcount(_:)
- Warren Moore, "Spatial Rendering for Apple Vision Pro" (secondary) — https://speakerdeck.com/warrenm/spatial-rendering-for-apple-vision-pro

Codebase: `extern/aurora` @ `cb2c340` (encounter/aurora). Key files cited inline in §3 and §5.1.

**Caveats:** Apple developer pages are JS-rendered, so a few quotes were confirmed via search
snippets rather than byte-level fetch. Frame-pacing specifics were a 2-1 verification. The IOSurface
Dawn↔Metal bridge (§5.0) is engineering inference from Dawn's documented capabilities, **not** a
cited working example — hence the spike in §7.
