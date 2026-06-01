# HANDOFF — visionOS True Per-Eye Stereo (Dusklight on Apple Vision Pro)

_Last updated: 2026-06-01. Branch: `visionos-stereo-depth`._

This supersedes the older black-screen handoff. Read top-to-bottom; §0 and §6–§7 are the
"what do I do next" parts. Persistent context also lives in the auto-memory at
`~/.claude/projects/-Users-dan-dev-dusklight/memory/` (esp. `visionos-device-anchor-required.md`,
`visionos-device-signing.md`, `aurora-is-webgpu-dawn.md`, `dan-runs-device-pushes-himself.md`).

---

## 0. TL;DR / current status

**Goal:** genuine per-eye stereoscopic depth for Dusklight (native Twilight Princess port) on
Apple Vision Pro, per `STEREO.md`. Render the 3D world twice (one projection per eye) and present
through a CompositorServices `ImmersiveSpace`.

**What works (committed, on device):** the game renders **mono** in correct color in a **full
ImmersiveSpace on the real AVP**. The months-long black screen and the magenta/color bug are solved
and committed (see §2/§3).

**What's in progress (committed as a WIP checkpoint this session — see §5):** the true two-pass
per-eye stereo ("Aurora command-list replay") + a mono fallback for 2D-UI screens. It compiles and
runs, but is **NOT working in-game yet** — blocked by two issues (§6):
1. The **game won't load on the AVP** — a JKR archive-heap panic on the DVD thread when mounting a
   disc archive (almost certainly a corrupt/truncated disc on the device; possibly a visionOS heap
   issue). This is NOT a stereo bug; it's the first time the game has actually tried to load on the
   device.
2. A **latent crash + wrong scaling in the replay**: `render_stereo_eye` runs the GX draw pipelines
   (built for the **MSAA, surface-format** EFB) straight into a **single-sample BGRA8** eye texture
   → pipeline/target mismatch that will abort the moment real geometry renders, and meanwhile the
   geometry is mis-scaled (EFB viewport ≠ eye texture size). One rework fixes both (§7 step 2).

**App state:** just uninstalled+reinstalled, so the container is fresh (no remembered disc) → it
boots to the prelaunch UI and no longer auto-crashes.

---

## 1. The goal & the chosen architecture (decisions)

Per `STEREO.md`: Aurora is WebGPU/Dawn (not native Metal), so Apple's single-pass vertex
amplification and layered render targets are unreachable. The realistic path is **render the scene
twice** into two IOSurface-backed eye textures and present them ourselves via a SwiftUI
`ImmersiveSpace` + `CompositorLayer`. The IOSurface↔Dawn↔Metal interop spike is **done and proven**
(that's the committed mono pipeline).

**Decision — how to render the second eye (the crux):** an Aurora investigation (two sub-agents)
established that Aurora records the whole frame's draws into a replayable command list
(`g_renderPasses[*].commands`). We chose **Aurora command-list replay** over driving the game's
render twice:
- The game renders **once** (mono) into the EFB; at `end_frame` Aurora **re-encodes the recorded GX
  draws a second time per eye** into two eye targets, with a per-eye projection patch.
- Rejected "game-loop double render" because `fapGm_Execute()` runs game logic+render together (can't
  call twice) and re-running the decomp draw risks state side-effects.
- **No WGSL shader change** (other platforms share the shaders) — the per-eye difference is patched
  into the projection bytes in a per-eye **copy** of the uniform buffer.

**Decision — the per-eye projection math (verified):** Aurora `Mat4x4` is row-major
(`out.pos = vec4f(mv_pos,1) * proj`), so `clip.x = dot(mv,m0)`, `clip.w = dot(mv,m3)`. A per-eye
clip-space x-shift `clip.x += A*clip.w + B` gives correct depth-dependent parallax for perspective
draws **and** parks orthographic (HUD) content on a fixed plane automatically. Baked into proj as,
per **perspective** draw (proj is 64 bytes; m0.x at +0, m0.z at +8, m0.w at +12):
```
m0.z -= convergence;            // A term  (zero-parallax plane)
m0.w += -eyeSep * m0.x;         // B term  (eye separation / parallax; scales with the draw's focal)
```
**Orthographic draws are left unpatched** (HUD/2D stays screen-fixed). Eye separation/convergence
are in **game units** (TP world scale ≠ meters) → on-device tuning knobs (§7 step 3). Left eye gets
`-eyeSep`, right `+eyeSep`; flip if depth is inverted.

**Decision — 2D UI:** the GX replay only covers 3D geometry; Dusk's RmlUi/ImGui (disc-select, menus,
console) are NOT in the GX list, so a UI-only frame would be black. Added a **mono fallback**: when a
frame has 0 GX draws, blit the normal composite into both eyes (flat, visible). In-game Dusk UI
overlays are still missing in stereo — a later "composite UI as a flat layer" follow-up.

**Decision — foundation-first** (user's choice) then wire the double-render. Done in that order.

---

## 2. What works & is committed (the milestone)

On `visionos-stereo-depth`:
- `847baa1d21` — real game frame visible in immersive space on device (the depth + color + layout
  config fixes). **This is the working mono milestone.**
- `d7e21a086f` — per-eye view/projection foundation logging (observation only).
- earlier: `229bf6857f`, `c27a70a777`, `d27ff4f9f2` (device-stable present checkpoints).
- aurora submodule was committed at `c61e9c1` (composited-capture-source fix); the WIP checkpoint
  (§5) adds a commit on top of it.

---

## 3. Root causes already solved (do NOT re-debug — also in memory)

- **★ Black screen on device = the drawable's DEPTH texture must be written+stored every frame.**
  visionOS reprojects using depth; the device blanks a frame whose depth wasn't produced (the
  simulator is lenient). Fix: attach `cp_drawable_get_depth_texture` with `loadAction=Clear,
  storeAction=Store`. This was THE black-screen cause; layout (dedicated vs layered) was a red herring.
- **Color/magenta = format mismatch.** The drawable defaulted to `RGBA16Float`; the BGRA8 capture
  IOSurface blitted into it cross-format → magenta + channel fringing. Fix: `configuration.colorFormat
  = .bgra8Unorm` (the AVP only offered `.bgra8Unorm_srgb` = rawValue 81; the unorm→srgb copy is valid
  and gamma-correct).
- Device-only CompositorServices strictnesses (all sim-lenient): device anchor per drawable,
  `.immersionStyle(.full)`, `cp_frame_query_drawables` array API, frame-timing handshake. See
  `visionos-device-anchor-required.md`.
- Swift API: conform to `CompositorLayerConfiguration` (NOT `_CompositorLayerConfiguration`);
  `makeConfiguration(capabilities:configuration:)`; `configuration.layout/.isFoveationEnabled/
  .colorUsage`; `capabilities.supportedLayouts/supportedColorFormats(options:)`.

**Real on-device numbers (from the foundation logging):** per-eye IPD offset ≈ ±0.0307 m;
off-axis skew ±0.268; eye color texture **1888×1792**, BGRA8Unorm_srgb (fmt 81), single-sample, no
foveation rate maps; the game's recorded render viewport is **2389×1792** (≠ the eye → the scaling
mismatch).

---

## 4. How the in-progress stereo path is wired (read with §5)

Engine thread (Dusk, `StereoPresent.mm`): publishes **two** IOSurfaces (L/R), imports them as Dawn
textures (`SharedEyeTexture g_eye[2]`), and each frame calls
`aurora::webgpu::set_stereo_eye_targets(leftView, rightView, w, h, eyeSepL, convL, eyeSepR, convR)`
bracketed by per-eye `BeginAccess`/`EndAccess` around `aurora_end_frame()`.

Aurora `end_frame`/`render`:
- `upload_stereo_eye_uniforms` (common.cpp): scans `g_renderPasses` to set `g_stereoFrameHadGx`;
  then (if eye targets armed) copies the frame's uniform bytes into two scratch buffers, patches each
  **perspective** GX draw's proj per eye (the clip-shift math, using `DrawData.projOffset`/`projOrtho`
  recorded in `command_processor.cpp`/`shader_info.cpp`), and uploads to `g_uniformBufferEye[2]`.
  **Runs before the staging buffer is unmapped** (the CPU bytes must still be live).
- `render`: if `has_stereo_eye_targets() && g_stereoFrameHadGx`, calls `render_stereo_eye(cmd,
  eyeView, eye)` for each eye **before `g_renderPasses.clear()`**. It replays the recorded commands
  into the eye color view (+ a throwaway offscreen depth), binding `g_uniformBindGroupEye[eye]` for
  GX draws via an eye-aware `gx::render` overload.
- `aurora.cpp` end_frame: **mono fallback** — if `has_stereo_eye_targets() && !stereo_frame_had_gx()`,
  blit `*stereoCaptureSource` into both eye views via `record_stereo_capture_blit_into`.

Present thread (`StereoPresent.mm`): waits on each eye's fence, blits `g_eye[0]`→view0,
`g_eye[1]`→view1 (left/right decided from `cp_view_get_transform` x sign via `logicalEyeForView`),
clears the drawable depth, presents.

**Tunables (top of `StereoPresent.mm`):** `kStereoEyeSep = 4.0f` (game units — pure guess),
`kStereoConvergence = 0.0f`.

---

## 5. Files touched this session + what changed

**Committed (Dusk, `847baa1d21` / `d7e21a086f`):**
- `src/dusk/vision/DuskVisionApp.swift` — `DuskLayerConfiguration: CompositorLayerConfiguration`
  (dedicated layout if supported, foveation off, `.renderTarget` color usage, `bgra8Unorm` color
  format); opens `ImmersiveSpace` with `.immersionStyle(.full)`.
- `src/dusk/vision/StereoPresent.mm` — depth clear+store in the present, command-buffer status
  diagnostics, per-eye foundation logging.

**WIP — committed this session as the WIP checkpoint (both the main repo and the aurora submodule):**
- `src/dusk/vision/StereoPresent.mm` — two eye IOSurfaces (`g_eye[2]`), per-eye blit,
  `set_stereo_eye_targets` call, `kStereoEyeSep`/`kStereoConvergence`, `logicalEyeForView`.
- `extern/aurora/lib/gx/pipeline.hpp` — `DrawData.projOffset` + `projOrtho`; eye-aware `gx::render` decl.
- `extern/aurora/lib/gx/pipeline.cpp` — `render_impl(...)` + eye-aware `gx::render` overload (swaps bind group 1).
- `extern/aurora/lib/gx/shader_info.{hpp,cpp}` — `build_uniform` records proj's byte offset (`outProjRel`).
- `extern/aurora/lib/gx/command_processor.cpp` — populate `projOffset`/`projOrtho` (uses `g_gxState.projType`).
- `extern/aurora/lib/gfx/common.{cpp,hpp}` — `g_uniformBufferEye[2]`/`g_uniformBindGroupEye[2]`,
  `g_stereoFrameHadGx`+`stereo_frame_had_gx()`, `upload_stereo_eye_uniforms`, `render_stereo_eye`,
  the per-eye replay gate in `render()`, the `stereo replay:` os_log diagnostic.
- `extern/aurora/lib/webgpu/gpu.{cpp,hpp}` — `set_stereo_eye_targets`/`has_stereo_eye_targets` +
  `StereoEyeTargets g_stereoEyeTargets`; `record_stereo_capture_blit_into` (+ `record_stereo_capture_blit`
  delegates to it). `set_stereo_capture_target` (mono) kept, now dormant.
- `extern/aurora/lib/aurora.cpp` — mono-fallback blit into both eyes when no GX.
- `extern/aurora/tests/gx_test_stubs.cpp` — stub `build_uniform` signature updated.

**Never commit `.claude/`** (untracked, intentional). The aurora submodule changes are committed
inside the submodule — do NOT `git submodule update` expecting it to no-op; the main repo points at
the new aurora WIP commit.

---

## 6. The two blockers (why in-game stereo isn't visible yet)

1. **Disc-load crash (BLOCKS reaching the game at all).** Crash report
   `/tmp/dusk_crashes/Dusklight-2026-06-01-121826.ips`: thread = **DVD thread**, `SIGABRT`,
   `abort()` from `aurora::Module::fatal`/`OSPanic` ← `JKRExpHeap::do_alloc` ←
   `JKRArchive::initFileDataPointers` ← `JKRDvdArchive::open` ← `mDoDvdThd_mountXArchive_c::execute`.
   I.e. a JKR archive heap ran out while mounting a disc archive. **Leading hypothesis: the disc
   image on the device is truncated/corrupt** (user said the prior one corrupted; the device tunnel
   has been flaky — installs needed retries). Alt hypothesis: visionOS heap-sizing issue (heaps in
   `src/m_Do/m_Do_machine.cpp:794-813` look like standard decomp sizes, not obviously mis-gated).
   Disambiguate by loading the same `rom.iso` in **desktop** Dusklight (`--dvd`). The local image
   `/Users/dan/dev/dusklight/rom.iso` is verified good (`GZ2E01` = TP USA, valid GC magic, 1048721408 B).

2. **Replay format/MSAA mismatch + scaling (BLOCKS the replay once geometry renders).** The EFB
   (`g_frameBuffer`) is created at `g_graphicsConfig.surfaceConfiguration.format` and **multisampled**
   (`create_render_texture(...,true)`, `gpu.cpp`). The recorded GX pipelines are therefore baked for
   (MSAA sampleCount, surface format). `render_stereo_eye` currently renders them directly into the
   **single-sample BGRA8** eye IOSurface → render-pipeline/render-pass incompatibility → Metal abort
   (only triggers when there ARE GX draws, i.e. in-game). Separately, it replays the recorded
   **EFB-space viewport** (2389×1792) into the 1888×1792 eye → mis-scaled/cropped (the "scaling and
   alignment is wrong" the user saw on the canvas).

---

## 7. NEXT STEPS (ordered)

**Step 1 — get a valid disc on the device.** Confirm `rom.iso` loads in desktop Dusklight
(`--dvd /Users/dan/dev/dusklight/rom.iso`). If it boots there, the device copy is the problem →
re-push and verify the on-device size matches 1048721408 bytes. Push command (**Dan runs this
himself** — see `dan-runs-device-pushes-himself.md`):
```
xcrun devicectl device copy to --device 6303AA5D-AE95-5D40-BAEE-B2E8C4AFEC3E \
  --domain-type appDataContainer --domain-identifier dev.twilitrealm.dusk \
  --source /Users/dan/dev/dusklight/rom.iso --destination Documents/rom.iso
```
If desktop also crashes loading, the `.iso` is bad. If it's neither (good image, good transfer) →
investigate the visionOS JKR heap sizing / total app-memory budget (separate sub-project).

**Step 2 — rework `render_stereo_eye` (fixes blocker #2: the latent crash AND the scaling).** Don't
render GX draws straight into the BGRA8 eye texture. Instead render each eye the way the mono path
renders the frame: into an **EFB-format, MSAA, EFB-size** color target (so the GX pipelines match) +
resolve, then **resample-fit** that into the eye IOSurface (BGRA8, eye size) — reuse the existing
resample/`record_stereo_capture_blit_into` path which already converts format + can letterbox-fit
(AURORA_VIEWPORT_FIT, 64:27). Concretely: per eye, clear+replay into an EFB-equivalent target with
the per-eye-patched uniforms, resolve, then resample into `g_stereoEyeTargets.view[eye]`. This makes
the eye image match what the mono capture produced (correct format/scale) but with per-eye geometry.

**Step 3 — tune stereo on device.** With the game loading and the replay valid, dial `kStereoEyeSep`
(start 4.0; raise/lower for comfortable depth), set `kStereoConvergence`, and flip the L/R eyeSep
sign if depth feels inverted. Verify with the `stereo replay: gxDraws=<large>` log (non-zero in-game).

**Step 4 — follow-ups (after stereo looks right):**
- In-game Dusk UI overlay (RmlUi/ImGui) missing in stereo — composite it as a flat layer over both eyes.
- **CPU-wake watchdog**: the present/engine loops spin too hot; the OS killed the app at ~52s
  (`caught waking the CPU 45001 times`). Add real frame pacing.
- **Mid-frame teardown crash**: `cp_frame_end_submission` BUG IN CLIENT when the layer is
  invalidated/headset-off mid-frame — bail cleanly on layer-state change.
- Trim memory: `g_uniformBufferEye[2]` are 24 MB each (48 MB) + two ~13.5 MB IOSurfaces; shrink the
  eye uniform buffers to the used size.
- Remove the verbose per-frame diagnostics; squash the WIP; eventually open a PR (this private fork
  allows AI-authored code — `dusklight-fork-ai-code-ok.md`).

---

## 8. Build / sign / install / run recipe

Verified IDs (`visionos-device-signing.md`): device `6303AA5D-AE95-5D40-BAEE-B2E8C4AFEC3E`, bundle
`dev.twilitrealm.dusk`, signing cert SHA1 `FF90CB4DBFB4B583ACD140487A599825BFFB09AF`
(Apple Development: Daniel Walter), entitlements at `/tmp/dusk_ent.plist` (recreate if /tmp cleared —
`application-identifier=39CTS9UG74.dev.twilitrealm.dusk`, `team-identifier=39CTS9UG74`,
`get-task-allow=true`, `keychain-access-groups=[39CTS9UG74.dev.twilitrealm.dusk, com.apple.token]`).
The `embedded.mobileprovision` already inside `build/visionos-default/Dusklight.app` survives rebuilds.

```
# Build (do NOT reconfigure — it would wipe the throwaway SDL patches under build/.../_deps;
# see visionos-build-recipe.md / visionos-sdl-swift-workaround.md). Already configured.
cmake --build /Users/dan/dev/dusklight/build/visionos-default
# (real errors = grep 'error:' minus the benign "DAWN Werror: OFF" line)

APP=/Users/dan/dev/dusklight/build/visionos-default/Dusklight.app
codesign --force --generate-entitlement-der --sign FF90CB4DBFB4B583ACD140487A599825BFFB09AF \
  --entitlements /tmp/dusk_ent.plist "$APP"
codesign --verify --deep --strict "$APP"
xcrun devicectl device install app --device 6303AA5D-AE95-5D40-BAEE-B2E8C4AFEC3E "$APP"   # retry on tunnel blips
```
**Launch from the headset Home View** (`devicectl ... process launch` STALLS on visionOS). World
tracking needs the headset worn + foregrounded. To clear a bad disc / reset: `devicectl device
uninstall app ... dev.twilitrealm.dusk` then reinstall (wipes the container).

---

## 9. Diagnostics (all via Console.app with the AVP selected; logs use NSLog/os_log = device-visible)

Filter `dusk::vision`. Key lines and meaning:
- `stereo replay: passes=N gxDraws=M eyeTarget=WxH firstVP=(x,y,wxh)` — `gxDraws=0` ⇒ 2D-UI-only
  frame (mono fallback, expected); `gxDraws>0` ⇒ in-game (the replay runs). `firstVP` vs `eyeTarget`
  shows the scaling mismatch.
- `view N eyeOffset=(x,y,z)m … projXX/projYY/skewX/skewY` — per-eye data from `cp_view`.
- `cmdbuf #N status=4 error=none` — the present command buffer executed (4=Completed).
- `engine imported two … eye textures; TRUE stereo ARMED (eyeSep=… conv=…)`, `blitted L+R eyes …`.

Pull a device crash log (no root needed; device must be UNLOCKED):
```
xcrun devicectl device copy from --device 6303AA5D-AE95-5D40-BAEE-B2E8C4AFEC3E \
  --domain-type systemCrashLogs --source <Name-YYYY-MM-DD-HHMMSS.ips> --destination /tmp/x.ips
# or --source . --destination /tmp/dusk_crashes/ to pull the whole dir, then find the newest Dusklight-*.ips
```
`.ips` is two JSON objects (header line + body); parse `faultingThread` + `threads[ft].frames` with
`usedImages` for names. `log collect --device-udid` needs root (sudo).

---

## 10. References
- `STEREO.md` — the design doc (architecture, injection points, perf).
- `docs/stereo-spike-interop.md` — the long device-debug log.
- Memory: `visionos-device-anchor-required.md` (★ depth + device strictnesses + Swift API + color
  format), `visionos-device-signing.md`, `visionos-build-recipe.md`, `visionos-sdl-swift-workaround.md`,
  `aurora-is-webgpu-dawn.md`, `dusklight-fork-ai-code-ok.md`, `dan-runs-device-pushes-himself.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
