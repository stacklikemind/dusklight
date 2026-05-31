# Spike: Dawn ↔ Metal ↔ CompositorServices interop

**Goal of this spike:** prove (or kill) the single load-bearing assumption behind the whole
visionOS stereo plan in [`../STEREO.md`](../STEREO.md) §5.0 — that Aurora's Dawn (WebGPU) renderer
can share a rendered texture with a native Metal CompositorServices present loop **without a CPU
copy**, and that we can drive a full `ImmersiveSpace` render loop at all from Dusklight's C/C++ host.

This is a **throwaway experiment**, not production code. Success criteria are binary. Do the minimum
to answer the question; do not build the real renderer here.

> **Why this first:** every other piece (per-eye matrix injection, two-pass render, off-axis frusta,
> head pose, foveation) is "known" engineering. The IOSurface bridge + immersive loop is the only
> unproven, architecture-defining unknown. If it fails we re-plan (Dawn patch, read-back path, or a
> different backend strategy) *before* sinking effort into the rest.

---

## 0. The question, stated precisely

> Can we allocate an `IOSurface`, render into it from Aurora's `wgpu::Device` (Dawn/Metal), wrap the
> **same** `IOSurface` as an `MTLTexture`, and blit it into a CompositorServices
> `drawable.colorTextures[viewIndex]` inside a SwiftUI `ImmersiveSpace`, presenting at the device
> refresh rate — with zero CPU copies of pixel data?

If yes → the §5 architecture is viable; proceed to the real implementation plan.
If no → record exactly *where* it breaks (Dawn API missing? import fails? layout/sync mismatch?
present stalls?) and choose a fallback (see §7).

---

## 1. Success criteria (binary)

1. **S1 — Immersive loop runs.** A `Full Space` `ImmersiveSpace` opens on the AVP (or visionOS sim),
   a CompositorServices `CompositorLayer` render loop ticks, and we present cleared drawables at the
   refresh rate for ≥30 s with no stalls. *(Validates the present plumbing independent of Aurora.)*
2. **S2 — IOSurface round-trips.** One `IOSurface` is imported into Dawn as a renderable
   `wgpu::Texture` **and** wrapped as an `MTLTexture`; we render a recognizable pattern via Dawn and
   read it back / see it via Metal. *(Validates the bridge in isolation, no compositor.)*
3. **S3 — End-to-end.** Aurora renders one real game frame (mono) into the IOSurface; the immersive
   loop blits that IOSurface into **both** eyes of the drawable; we see the game frame, head-locked,
   on the headset. *(Validates the full path. Mono-to-both-eyes is fine here — depth comes later.)*
4. **S4 — No CPU copy.** Confirm via Instruments / code audit that pixels never transit CPU memory
   (no `getBytes`/`replaceRegion`/staging-buffer readback in the steady-state path).

Stretch (nice signal, not required to call the spike done):
- **S5** — drive two IOSurfaces and blit each to a different eye (proves the per-eye plumbing).
- **S6** — apply the per-eye `cp_view` transform to a debug quad so left/right differ (first taste of
  real parallax).

---

## 2. Prerequisites & ground truth to confirm in Step 0

Several assumptions were **verified during planning** (against `extern/aurora` @ `cb2c340`); these are
marked ✅ with `file:line`. The remaining unchecked items are the genuine Step-0 unknowns. Dawn's
shared-resource API has churned across versions, so still verify exact enum spelling against the
**actual Dawn version that builds for visionOS** (see the build gotcha below).

- [x] ✅ **Aurora exposes its `wgpu` device/queue/instance/surface.** Confirmed globals in
  `extern/aurora/lib/webgpu/gpu.hpp:42-52`:
  `extern wgpu::Device g_device; wgpu::Queue g_queue; wgpu::Surface g_surface;
  wgpu::BackendType g_backendType; wgpu::Instance g_instance;` (all in `namespace aurora::webgpu`).
  Reachable from a Dusk-side file by including `lib/webgpu/gpu.hpp`, or add a 1-line public accessor
  to avoid reaching into Aurora internals.
- [x] ✅ **Device creation has a feature-request site to hook.** `gpu.cpp:804` builds
  `std::vector<wgpu::FeatureName> requiredFeatures;` and passes it at `gpu.cpp:851-852`
  (`requiredFeatureCount`/`requiredFeatures`), alongside a `wgpu::DawnTogglesDescriptor` at `:841`.
  **This is exactly where we add** `wgpu::FeatureName::SharedTextureMemoryIOSurface` and a shared-fence
  feature (e.g. `SharedFenceMTLSharedEvent`) — *if* the linked Dawn exposes them. Adapter must
  advertise them first (query before requiring).
- [ ] ⚠️ **Dawn build for visionOS + shared-texture feature availability.** Two linked unknowns:
  - **Build gotcha:** `AuroraDawnProvider.cmake:83` only lists prebuilt Dawn packages for
    `windows/linux/darwin/ios-arm64/android` — **visionOS is NOT covered**, so on xrOS the provider
    falls back to `system` (`find_package(Dawn)`) or `vendor` (FetchContent build from source via
    `AURORA_DAWN_REF`). Decide/confirm how Dawn is supplied for the visionOS build *before* spiking
    (likely a vendor source build, or a self-built package URL). `DAWN_ENABLE_METAL` is `ON` on Apple
    (`:27`).
  - **Feature:** confirm that Dawn version exposes `wgpu::SharedTextureMemory` +
    `SharedTextureMemoryIOSurfaceDescriptor` (or `dawn::native::metal::*` import), and that the adapter
    advertises it on visionOS. No IOSurface/SharedTextureMemory usage exists in Aurora today (grep
    clean) — we are adding it.
- [ ] ⚠️ **Shared fences.** For correct Dawn→Metal ordering we likely need `wgpu::SharedFence`
  (Metal `MTLSharedEvent`). Confirm availability; if absent, fall back to an explicit
  `queue.OnSubmittedWorkDone` / `MTLSharedEvent` handshake (coarser, note the perf cost).
- [x] ✅ **Aurora offscreen render target path exists.** `GXCreateFrameBuffer`/`GXRestoreFrameBuffer`
  (`include/dolphin/gx/GXAurora.h:119/125`) → `gfx::begin_offscreen`/`end_offscreen`
  (`lib/gfx/common.cpp:383/430`); per the header, offscreen content is resolved into a texture via
  `GXCopyTex`. Still confirm whether we can make it resolve into **our** IOSurface-backed texture, or
  must mirror its format/usage and copy once.
- [x] ✅ **Aurora frame loop / present site.** `lib/aurora.cpp`: `g_surface.GetCurrentTexture` (`:219`),
  `g_surface.Present()` (`:332`), wrapped by `aurora_begin_frame`/`aurora_end_frame` (`:370-371`).
  For the spike we bypass this present (we present via CompositorServices instead) but still drive
  Aurora's frame to render into the offscreen target.
- [ ] **Texture format agreement.** Pick one format end-to-end (e.g. `BGRA8Unorm` /
  `wgpu::TextureFormat::BGRA8Unorm` / `MTLPixelFormatBGRA8Unorm`) supported as renderable by Dawn,
  as an `IOSurface` pixel format, and as a CompositorServices color format. Confirm color space
  (sRGB vs linear) handling so we don't double-encode gamma.
- [ ] **Build/signing.** The immersive entitlement + provisioning already work for the existing
  visionOS app (see `CLAUDE.md` → "Running"). Confirm `com.apple.developer.arkit` / immersive-space
  usage is permitted by the profile; add Info.plist keys if the simulator complains.
- [x] ✅ **`TARGET_OS_VISION` gating.** Per `CLAUDE.md`, `TARGET_OS_IOS == 0` on visionOS — gate all
  spike code on `TARGET_OS_VISION`, not `TARGET_OS_IOS`. (Confirmed pattern; Aurora's `window.cpp`
  does not special-case visionOS either.)

---

## 3. Build order (each step independently verifiable)

Do these strictly in order; each de-risks the next. Stop and record if any step fails.

### Step A — Immersive present skeleton (no Aurora) → validates **S1**
1. Add a SwiftUI `ImmersiveSpace` + `CompositorLayer` to the visionOS target (new throwaway
   `StereoSpike` scene, behind a launch flag so it doesn't disturb the normal app).
2. In the `CompositorLayer` closure, hand the `LayerRenderer` to a C entry point
   (`dusk_spike_engine_create(layerRenderer)`), mirroring the WWDC2024 10092 structure.
3. Implement the minimal render loop in C/C++ (or Swift first, then port): wait for the next frame,
   `queryDrawable`, get `cp_view`s, **clear each eye's color texture to a distinct color** (left=red,
   right=blue), present. Run ≥30 s.
4. **Gate:** distinct colors per eye, stable refresh, no stalls → S1 ✅.

### Step B — IOSurface ↔ Dawn ↔ Metal in isolation → validates **S2 / S4**
1. Allocate one `IOSurface` (chosen format/size, `kIOSurfaceIsGlobal`-free, GPU-usable).
2. Import it into Aurora's `wgpu::Device` as a renderable `wgpu::Texture` (via the API confirmed in
   Step 0). Render a test pattern (e.g. a clear + triangle) into it through Dawn.
3. Wrap the **same** `IOSurface` as an `MTLTexture` (`device.makeTexture(descriptor:iosurface:plane:)`).
4. Insert the Dawn→Metal sync (shared fence / `MTLSharedEvent`, or a conservative
   `queue.OnSubmittedWorkDone` barrier for the spike).
5. Verify the Metal side sees the Dawn-rendered pattern (blit to a small on-screen quad in a plain
   window build, or read back once for the test only).
6. **Gate:** pattern visible through Metal, and (audit) no per-frame CPU pixel copy → S2 ✅, S4 ✅.

### Step C — Wire Aurora's real frame in → validates **S3**
1. Make Aurora render its normal mono game frame into the IOSurface-backed texture (via the
   offscreen FB path, or temporarily retarget the EFB resolve). One frame is enough; a live stream is
   the stretch goal.
2. In the Step-A immersive loop, replace the clear with a **Metal blit** of the IOSurface-backed
   `MTLTexture` into `drawable.colorTextures[viewIndex]` for **both** eyes.
3. Add the sync so the blit waits on Aurora's submit.
4. **Gate:** the game frame appears on the headset in both eyes, head-locked → S3 ✅.

### Step D (stretch) — first parallax → **S5 / S6**
- Two IOSurfaces, one per eye; or apply each `cp_view` transform to a debug quad so the two eyes
  differ. Not required to declare the spike successful, but a strong confidence signal for §5.

---

## 4. Scope guards (do NOT do these in the spike)

- ❌ Per-eye projection matrix injection into Aurora (`shader.cpp`/`build_uniform`) — that's the real
  implementation, not the spike.
- ❌ Two-pass scene rendering. Step C renders **one** mono frame to **both** eyes on purpose.
- ❌ ARKit head pose with predicted `presentationTime`. Head-locked is fine for the spike; pose comes
  in the real build. *(If S1 is trivial, optionally fold in a basic `queryDeviceAnchor` to de-risk
  the ARKit session setup — but don't block on it.)*
- ❌ Foveation / dynamic render quality / 60→90 Hz pacing tuning.
- ❌ Clean architecture, abstractions, or config plumbing. Hardcode everything.

---

## 5. Files / surfaces likely touched (spike-local)

- `platforms/visionos/` — new throwaway `ImmersiveSpace`/`CompositorLayer` scene + launch flag.
- A new Dusk-side `src/dusk/ios/` (or `src/dusk/vision/`) C++/ObjC++ file for the spike engine entry
  (`dusk_spike_engine_create`) and the Metal blit. Gate on `TARGET_OS_VISION`.
- Possibly a 1-line accessor in `extern/aurora/lib/webgpu/gpu.{hpp,cpp}` to expose the device/queue
  (or read the existing globals). Keep any Aurora edit minimal and clearly marked.
- `files.cmake` — register the new spike source(s) in `DUSK_FILES` (per `CLAUDE.md`).
- No changes to `STEREO.md` injection points yet.

> Reminder (`CLAUDE.md`): this project does not accept primarily AI-generated contributions, and SDL
> changes are off-limits. Keep spike code human-authored and avoid touching vendored SDL.

---

## 6. Risks & what each failure tells us

| Risk | Symptom | Implication / next move |
|---|---|---|
| No prebuilt Dawn for visionOS (`AuroraDawnProvider.cmake:83`) | xrOS build falls to `system`/`vendor` Dawn | Settle Dawn sourcing for visionOS first (vendor source build or self-built package URL); blocks everything if unresolved |
| Dawn build lacks Metal shared-texture import | No `SharedTextureMemory`/IOSurface API; adapter doesn't advertise feature | Must enable the Dawn feature/toggle at `gpu.cpp:804/851`, or patch/rebuild Dawn → re-evaluate effort; consider read-back fallback |
| Missing shared-fence primitive | Tearing / garbage / race between Aurora submit and Metal blit | Use `MTLSharedEvent` bridged both ways, or coarse `OnSubmittedWorkDone` barrier (perf cost — note it) |
| Format / color-space mismatch | Wrong colors, gamma off, validation errors | Pin one renderable+IOSurface+CompositorServices format; handle sRGB explicitly |
| Present stalls / wrong cadence | Loop hitches, dropped frames | Verify we present exactly one drawable per compositor update; check we're not double-waiting |
| Immersive entitlement/signing | Space won't open on device | Fix profile/Info.plist; validate on simulator first |
| Aurora offscreen can't target our texture | `begin_offscreen` allocates its own RT | Mirror its format/usage; or add a minimal "render to supplied texture" hook |
| CPU copy sneaks in | S4 audit fails | Find the staging path; if unavoidable in this Dawn version, the whole zero-copy premise weakens → re-plan |

---

## 7. Decision tree after the spike

- **All of S1–S4 pass** → architecture confirmed. Write the real implementation plan: per-eye matrix
  injection (STEREO.md §5.1), two-pass render, off-axis frusta from `cp_view_get_tangents`, ARKit
  head pose at `presentationTime`, foveation + dynamic render quality, 60→90 Hz pacing.
- **S1 passes, S2/S3 fail on Dawn import** → fallback options, in rough preference order:
  1. Enable/patch the Dawn Metal shared-texture feature and rebuild (cost: vendored-Dawn patch to
     maintain).
  2. Read-back path (Aurora → CPU → Metal upload) as a *correctness-first* prototype to validate the
     rest, accepting the copy cost, then optimize.
  3. Bypass Dawn's present and reach the underlying `MTLTexture` of Aurora's own render target
     directly (if the Dawn version exposes native texture handles).
- **S1 fails** → the problem is the immersive/CompositorServices loop itself (signing, API misuse) —
  independent of Aurora; resolve before anything else.

---

## 8. Definition of done for this spike

A short written result (append to this file or a new `docs/stereo-spike-results.md`) stating:
- Which of S1–S6 passed, with a screenshot/recording for S3.
- The **exact** Dawn shared-texture API used (names + version), and the sync mechanism.
- The chosen pixel format + color-space handling.
- Confirmation (Instruments or audit) of zero CPU copy, or a description of where the copy is.
- A go / no-go recommendation for the §5 architecture, and if no-go, which §7 fallback to pursue.

---

## 9. Step 0 results & progress log

### 9.1 Step 0 — RESOLVED (verified against `extern/aurora` @ `cb2c340` + on-disk build)

- **Dawn pin:** `AURORA_DAWN_VERSION = v20260523.201736`, `AURORA_DAWN_REF =
  9aa45f938d4b36626722bbfdc2f18447179337e6` (`extern/aurora/CMakeLists.txt:17-18`),
  `AURORA_DAWN_PROVIDER = auto`.
- **visionOS Dawn sourcing:** the prebuilt-package list (`AuroraDawnProvider.cmake:83`) excludes
  visionOS, so the xrOS build resolves to **`vendor`** (FetchContent source build). **Already built**
  on disk: `build/visionos-{default,sim-default}/_deps/dawn-{src,build}`. No sourcing work needed.
- **Shared-texture bridge is expressible with the pinned Dawn — biggest risk RETIRED.** Confirmed in
  `build/visionos-sim-default/_deps/dawn-build/gen/include/dawn/webgpu_cpp.h`:
  `wgpu::SharedTextureMemory` (~2023), `wgpu::SharedFence`,
  `FeatureName::SharedTextureMemoryIOSurface` (`WGPUFeatureName 0x00050024`),
  `FeatureName::SharedFenceMTLSharedEvent` (`0x0005002A`), `SharedTextureMemoryIOSurfaceDescriptor`
  (~3132), `Device::ImportSharedTextureMemory` (~1793), `SharedTextureMemory::BeginAccess/EndAccess`
  (~2028/2030), `SharedTextureMemoryMetalEndAccessState`. Native impl compiled in
  (`SharedTextureMemoryMTL.mm`, `SharedFenceMTL.mm`). **No Dawn bump required.**
- **App boot:** SDL-driven classic `main` (`SDL_main.h` redefines `main`→`aurora_main`; on
  iOS/visionOS `SDL_RunApp`→`UIApplicationMain` with `SDLUIKitDelegate`). No SwiftUI. Frame loop is a
  hand-rolled `while` in `src/m_Do/m_Do_main.cpp` driving `aurora_begin_frame`/`aurora_end_frame`.
  **Seam for ImmersiveSpace:** subclass via SDL's documented `+[SDLUIKitDelegate
  getAppDelegateClassName]` hook (Dusk-side subclass — NOT an SDL edit) to activate a
  CompositorServices immersive scene alongside SDL's `CAMetalLayer` window. Current
  `platforms/visionos/Info.plist.in` has a single UIKit window scene, no `UISceneDelegateClassName`,
  and **no high-refresh / `CAFrameRateRange` key**.

### 9.2 Foundations LANDED (compile-verified, target `aurora_gx`)

`cmake --build build/visionos-sim-default --target aurora_gx` → links `libaurora_gx.a` clean:

1. **Request shared-texture features** (`lib/webgpu/gpu.cpp`, inside the existing `supportedFeatures`
   enumeration ~808): under `#if defined(__APPLE__)`, also push `SharedTextureMemoryIOSurface` +
   `SharedFenceMTLSharedEvent` when the adapter advertises them. Mirrors the `TextureCompressionBC`
   idiom; silent skip otherwise. ✅ Solid.
2. **`begin_offscreen_external(colorTargetView, w, h)`** (`lib/gfx/common.{hpp,cpp}`): factored
   `begin_offscreen` into a shared impl; external variant uses a caller-supplied color view (depth
   still internal). Internal `begin_offscreen` preserved. ⚠️ See 9.3.

### 9.3 ⚠️ Caveat in `begin_offscreen_external` (do not skip)

`render()` (`common.cpp:768-773`) **skips any non-final render pass with no `resolveTarget`**, and
the external variant sets no resolveTarget (caller owns the result). The normal path avoids the skip
because `GXCopyTex` sets a resolveTarget. **So an external pass renders reliably only as the FINAL
pass** — not a robust whole-frame-capture primitive. (Minor: it also still allocates an unused
internal color texture.) **Recommended whole-frame path = present-stage capture** (Step C's
"retarget the EFB resolve"): in `aurora.cpp end_frame`, after `present_source()`/
`resample_present_source()`, blit the resolved image into the IOSurface-backed texture (reuse
`g_CopyPipeline`) alongside the swapchain. `begin_offscreen_external` stays as a final-pass-only
niche primitive.

### 9.4 Next implementation chunks (revised)

1. **IOSurface import + fence sync** (webgpu layer): `Device::ImportSharedTextureMemory` from an
   `IOSurface*`; per-frame `BeginAccess`/`EndAccess` with `SharedFenceMTLSharedEvent`. Compile-checkable.
2. **Present-stage capture** (`aurora.cpp end_frame`): blit present source → imported IOSurface
   texture (per 9.3). Compile-checkable.
3. **Step A — ImmersiveSpace present** (visionOS, sim/device-dependent): SDL-delegate subclass seam +
   CompositorServices loop + Metal blit of the IOSurface into `drawable.colorTextures[viewIndex]`.
   **Cannot be fully verified headless** — needs sim iteration.
4. Then real stereo (`../STEREO.md` §5.1): per-eye matrix injection, two-pass render, off-axis
   frusta, ARKit head pose, foveation.

### 9.5 Chunks 1–3 status (implemented; compile-verified to the object level)

All three landed and **compile** (objects present in `build/visionos-sim-default`):

- **Chunk 2 — Aurora present-stage capture** (`lib/webgpu/gpu.{cpp,hpp}`, `lib/aurora.cpp`):
  `set_stereo_capture_target` / `has_stereo_capture_target` / `record_stereo_capture_blit`. In
  `end_frame`, after the unchanged swapchain present, blits the already-resolved present source into
  the registered external view (reuses `g_CopyPipeline` + `create_copy_bind_group`). ✅ `aurora_gx`
  links clean. Caller owns `BeginAccess`/`EndAccess`.
- **Chunk 1 — IOSurface↔Dawn bridge** (`src/dusk/vision/StereoBridge.{h,mm}`):
  `dusk::vision::SharedEyeTexture` — `ImportSharedTextureMemory` from
  `SharedTextureMemoryIOSurfaceDescriptor{.ioSurface}`, `memory.CreateTexture` (usage
  `RenderAttachment|CopyDst|TextureBinding`), `BeginAccess`/`EndAccess`, MTLSharedEvent fence export
  via `SharedFenceMTLSharedEventExportInfo`, IOSurface-backed `MTLTexture` for the present side, and
  `createBGRA8IOSurface`. ✅ compiles. ⚠️ fence export path compiled but **not runtime-verified**;
  coarse-poll fallback is a TODO.
- **Chunk 3 — CompositorServices present loop + scene seam** (`src/dusk/vision/StereoPresent.{h,mm}`):
  full `cp_*` loop (query frame/drawable, per-view `MTLBlitCommandEncoder` copy into
  `cp_drawable_get_color_texture`, `encodeWaitForEvent` on the fence, `cp_drawable_encode_present`).
  ✅ compiles. Scaffold limits: mono-into-both-eyes; identity head pose (ARKit anchor = TODO).
  **Scene-activation seam — RESOLVED at compile/link level (2026-05; runtime unverified).**
  `cp_layer_renderer_t` has no C creation API (verified against the XROS 26.5 SDK headers) — it is
  vended only by a SwiftUI `ImmersiveSpace { CompositorLayer { layerRenderer in … } }`. Implemented a
  **visionOS-only SwiftUI `@main`** (`src/dusk/vision/DuskVisionApp.swift`) that: (1) spawns the
  existing engine entry (`aurora_main`) on a background thread via the C shim
  `dusk_vision_run_engine`, and (2) opens the ImmersiveSpace, captures the vended `LayerRenderer`, and
  hands it (as an opaque ptr) to `dusk_vision_start_present` → `runStereoPresentLoop`. C bridge in
  `StereoEntry.h` (Swift `-import-objc-header`).

  **Entry-point displacement (no SDL edits):** Swift's `@main` defines `_main`; aurora's `int main`
  lives in the `aurora::main` **static archive** (`lib/main.cpp.o`), pulled only if `main` is
  otherwise undefined — so it is NOT extracted (verified: binary has the Swift `_main`, aurora's
  `main.cpp.o` not pulled, no duplicate-symbol error). SDL's `UIApplicationMain` shim therefore never
  becomes the entry.

  **Build integration (CMakeLists `if (VISIONOS)`):** Swift enabled at top-level (Ninja+ios.toolchain
  can't `enable_language` mid-configure); clang-only flags (`-Wno-declaration-after-statement`,
  `-fsigned-char`) scoped via `$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>` genexes so they don't reach
  swiftc; Swift built as its **own static lib** (`dusk_vision_swift`) to avoid game flag/define
  leakage; `-force_load`ed so `@main` is retained. **Final-link fix (Option 1):** forced
  `LINKER_LANGUAGE CXX` so clang++ (not swiftc) drives the executable link — swiftc rejects the
  clang/ld-style flags abseil/Dawn inject (`-Wl,-framework,CoreFoundation`); added
  `-L <SDK>/usr/lib/swift` + `-rpath /usr/lib/swift` so autolinked `-lswift*` resolve.

  **Verified:** device target `cmake --build build/visionos-default` → **EXIT 0**; 49.5 MB
  `MH_EXECUTE` with `LC_MAIN`; `nm` shows `DuskVisionApp` ×27, `dusk_vision_run_engine`/
  `dusk_vision_start_present`/`runStereoPresentLoop`; `otool -L` shows `libswiftCore.dylib` +
  `libswiftCompositorServices.dylib`. **NOT verified (no device/sim run):** whether SDL's window/input
  lifecycle coexists with a SwiftUI-owned app, whether the ImmersiveSpace actually opens, and whether
  the IOSurface present round-trip displays. That is the next milestone (a real device run).

  **Device deploy DONE (2026-05-31):** the Swift-`@main` device build was signed (cert
  `Apple Development: Daniel Walter (ACFWRG37JV)` / SHA1 `FF90CB4D…`, team `39CTS9UG74`, reusing the
  app's existing `embedded.mobileprovision`) — `codesign --verify` "valid on disk / satisfies its
  Designated Requirement" — and **installed** to "Apple Vision Pro von Daniel" (devicectl
  `6303AA5D-…`, UDID `00008112-000621360C78A01E`): `App installed: bundleID dev.twilitrealm.dusk`,
  confirmed in the device app list. Recipe saved to memory `visionos-device-signing.md`.
  **Launch NOT yet performed from the agent:** `devicectl device process launch` reproducibly
  **stalls on visionOS** (acquires tunnel + usage assertion, then hangs; app never enters the process
  table) — this is the documented CLAUDE.md limitation. The app must be **launched from the headset
  Home View** by the user. So the runtime unknowns above (SDL+SwiftUI coexistence, ImmersiveSpace
  opening, IOSurface present) remain open pending that manual launch + log capture.

  **DEVICE RUN RESULT (2026-05-31): CRASHES ON LAUNCH — SDL/SwiftUI main-thread conflict.**
  Launched from the headset Home View; bounces straight back to Home. Crash logs pulled via
  `xcrun devicectl device copy from --domain-type systemCrashLogs` (11 crashes 16:03–16:06).
  Signal **`EXC_CRASH / SIGABRT`, "abort() called"**. Faulting thread = the **engine thread we spawn
  from Swift `@main`**:
  ```
  abort ← aurora_log_callback ← aurora::Module::fatal ← aurora_initialize.cold.1 ← aurora_initialize
        ← game_main ← aurora_main ← closure in engineStart (Swift Thread.detachNewThread)
  ```
  Root cause: `aurora.cpp:66-70` `initialize()` does `SDL_Init(SDL_INIT_VIDEO|GAMEPAD|JOYSTICK)`; on
  failure it `LOG_FATAL`/`ABORT()`s. **`SDL_Init(SDL_INIT_VIDEO)` fails because it runs on a background
  thread** — SDL's UIKit video subsystem must init on the **main thread**, which the SwiftUI `App` now
  owns. (Compounding: we start the engine in `DuskVisionApp.init()`, before the UIApplication/scene is
  even ready — thread 0 is still in `MRUIKit … mrui_prepareForMixedReality`.) The existing flat
  visionOS port works precisely because SDL owns `UIApplicationMain`/the main thread; moving SDL off
  the main thread breaks its video init. **This is the SDL↔SwiftUI coexistence risk flagged earlier,
  now confirmed at runtime.**

  **Implication — the "Swift `@main` + engine on a background thread" structure does not work as-is.**
  Resolving it is a real architecture decision (see options in the next section); not a one-line fix.

### 9.7 Open architecture decision: reconcile SDL's main thread with SwiftUI's

Both SDL (UIKit video init + window + event pump) and SwiftUI (`@main` run loop) demand the **main
thread**; `cp_layer_renderer_t` is *only* vended by a SwiftUI `ImmersiveSpace`/`CompositorLayer` (no C
API). The engine-on-background-thread approach aborts in `SDL_Init(VIDEO)`. Candidate paths, each with
real cost:

1. **Marshal only the UIKit-touching init to the main thread.** Keep SwiftUI `@main`; run the engine
   loop on a background thread BUT execute `SDL_Init(VIDEO)` + `SDL_CreateWindow` (and the SDL event
   pump) on `DispatchQueue.main`. Requires splitting Aurora's monolithic init/loop (`m_Do_main` +
   `aurora_initialize`) so the UIKit-bound bits run on main while the GX frame loop runs off-main —
   non-trivial Aurora surgery, and SDL event pumping must stay on main.
2. **Headless Aurora on visionOS (no SDL video/window).** Since we present via CompositorServices, the
   SDL `CAMetalLayer` window isn't needed. Init SDL without `SDL_INIT_VIDEO`, skip `create_window`, and
   feed Aurora a Metal device/surface from the CompositorLayer instead of `SDL_Metal_GetLayer`.
   Cleanest long-term for stereo, but Aurora's surface/swapchain/input are SDL-window-coupled — sizable
   rework, and input (controllers) needs a non-SDL-window path.
3. **Keep SDL as `@main`; host SwiftUI immersive from within the UIKit app.** Revert the Swift `@main`;
   from SDL's UIApplication, drive a SwiftUI immersive scene (e.g. `UIHostingController`/scene request
   for the ImmersiveSpace). Uncertain whether an ImmersiveSpace/CompositorLayer can be vended outside a
   SwiftUI `App` scene graph — needs validation; may not be supported.

Recommendation: **#1 is the smallest viable step** (keeps SwiftUI vending the layer, keeps SDL, just
fixes threading), with **#2 as the cleaner eventual target**. Either is a real chunk of work and the
next decision point — not attempted yet.

Build wiring: an `if (VISIONOS)` block in `CMakeLists.txt` (NOT `files.cmake` — the `dusklight`
target is built from per-target sources on this branch; `target_sources` is correct) adds the two
`.mm` with `-fobjc-arc` + `SKIP_PRECOMPILE_HEADERS ON`, links Metal/IOSurface/CompositorServices,
and adds the Aurora `lib` + Dawn `gen/include` paths.

### 9.6 ✅ RESOLVED: visionOS-sim app now links, stereo TUs bound into the binary

The whole-app sim link previously failed with undefined `_png_*` from
`libaurora_gx.a(png_io.cpp.o)`. **Root cause (diagnosed):** Aurora's `extern/extern/CMakeLists.txt`
sets `_USE_SHARED = ON` whenever `BUILD_SHARED_LIBS` is undefined, so `PNG::PNG` aliased the libpng
**shared dylib** — and that dylib **exports 0 `png_*` symbols** on this Apple toolchain
(`nm -gU libpng16.16.58.0.dylib` → empty; the working static `libpng16.a`, 967 KB, has them). The old
device binary linked the static `.a` from an earlier config; the regenerated sim config picked the
broken dylib.

**Fix (Aurora submodule, `extern/extern/CMakeLists.txt`):** force the bundled deps static on Apple —
`if (APPLE) set(_USE_SHARED OFF) endif()`. Loose dylibs aren't shippable in an iOS/visionOS/tvOS
bundle anyway, and Dawn linkage stays independent via `AURORA_DAWN_LINKAGE`. Reconfigure with
`cmake <build> -UBUILD_SHARED_LIBS`; the sim link then references `libpng16.a` (static). **This
single fix resolved the link — there was NO second blocker.** (The `SDLUIKitDelegate (DuskVision)`
category in `StereoPresent.mm` is already fully `//`-commented and contributes no symbol. An earlier
revision of this note claimed a second failure + an `#if 0` wrap; that was a mistake driven by flaky
tool output — no such second failure occurred and `StereoPresent.mm` is unchanged.)

**Result (verified against artifacts):** `cmake --build build/visionos-sim-default` → **EXIT 0**;
`build/visionos-sim-default/Dusklight.app/Dusklight` (**43.88 MB**) produced for the first time; a
follow-up incremental build reports "ninja: no work to do" (steady state). `nm` on the binary
confirms the stereo TUs are bound in: `dusk::vision` ×12, Aurora `*_stereo_capture_*` hooks ×3,
`SharedEyeTexture` ×9, `presentStereoFrame`/`runStereoPresentLoop`/`createBGRA8IOSurface` ×1 each.
So **Chunks 1–3 now link into the app** (upgraded from compile-only). Still unproven: runtime
behavior (no device/sim run yet) and the scene-activation seam (Step A / S1).
