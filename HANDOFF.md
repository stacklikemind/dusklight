# HANDOFF — visionOS stereoscopic present (branch `visionos-stereo-depth`)

_Last updated: 2026-05-31 ~23:00. This file is the quick-start for a fresh session. The full,
blow-by-blow record is in [`docs/stereo-spike-interop.md`](docs/stereo-spike-interop.md) §9.10–§9.16 —
read §9.16 first (it has the exact "resume here" steps)._

## TL;DR

Goal: render Dusklight into a true per-eye **stereoscopic** view on Apple Vision Pro via a
CompositorServices `ImmersiveSpace`, fed by Aurora's rendered frame through a shared IOSurface
(architecture: [`STEREO.md`](STEREO.md) §5; spike plan: `docs/stereo-spike-interop.md`).

**Where we are:** the whole CompositorServices + ARKit + IOSurface plumbing now works and is **stable
on a real Vision Pro** (no crash, head-tracked). The mono-into-both-eyes game frame is **proven
rendering on the visionOS simulator**. The ONE remaining device gap: the engine→IOSurface content
pipeline doesn't engage on device yet (drawables present with a valid anchor but empty → black). True
per-eye stereo (different image per eye) is future work after content shows.

## What we accomplished (this session)

Sim (visionOS 26.5 simulator) — **verified working, with a disc**:
- Step C end-to-end: Aurora renders the game frame → blits into a shared IOSurface (its "stereo
  capture target") → CompositorServices present loop blits that into both eyes → visible, head-locked.
- Prelaunch "Select Disc" / title UI renders too (the capture follows the RmlUi-composited image, not
  the bare game framebuffer).

Device (Apple Vision Pro, visionOS 26.5) — **all of these device-only blockers fixed & verified**:
1. Launch crash `cp_frame_end_submission` `BUG_IN_CLIENT` → use the visionOS-26 `cp_frame_query_drawables`
   array API (the deprecated single `cp_frame_query_drawable` aborts on device).
2. "Presenting a drawable without a device anchor" → must attach an ARKit head-pose **device anchor**
   to every drawable (sim doesn't enforce this).
3. "...can only be queried when the world tracking provider is running" → start the ARKit session on
   the **main thread**; gate the query on `ar_data_provider_get_state == running`.
4. Layered drawable (`texCount=1, viewCount=2`: one 2D-array color texture, slice == view) → blit the
   eye into each slice (sim was dedicated-per-view; blitting only slice 0 left the right eye black).
5. **★ The key fix:** keep ALL ARKit objects alive as process-lifetime statics (the config + the
   `ar_data_providers_t` collection, not just session/provider). They were ARC-freed right after
   `ar_session_run`, so the provider never reliably reached `running`. After the fix: provider reaches
   `running` in ~0.3s, `device anchor tracked=1`, drawable-drop errors stop, **app stable, no crash.**

## Key decisions / hard-won facts (don't re-litigate)

- **ARKit in C, not Swift.** Apple's fully-immersive Metal samples use the C ARKit API; the Swift
  `WorldTrackingProvider` doesn't cleanly bridge to the C `ar_world_tracking_provider_t` the present
  loop needs. We do ARKit in C and it works. (A Swift-managed refactor was considered and shelved.)
- **Never gate `cp_drawable_encode_present`/`commit` on having an anchor.** After `query_drawables` +
  `start_submission` you MUST present every drawable + commit before `end_submission`, else
  `BUG_IN_CLIENT` crash on frame 1. Always present; the compositor itself harmlessly drops frames
  whose anchor isn't tracked yet.
- **A fabricated identity anchor is rejected** ("device anchor has invalid tracking") — only a real
  *tracked* anchor counts. So content is gated on world tracking actually running (it now does).
- **Threading:** Dawn device work (SharedEyeTexture import / Begin/EndAccess, set_stereo_capture_target)
  must run on the **engine thread** (Dawn isn't thread-safe). The present loop (Metal blit, anchor
  query — `AR_MT_UNSAFE`) runs on its own **present thread**. They share the eye via atomics + a fence.
- **Test workflow:** world tracking only runs while the **headset is worn**; taking it off to read
  Mac logs stops tracking. Read device logs via **Console.app** (select the AVP) — it shows os_log
  mostly un-redacted; the `.ips` crash files only store the `"%s"` format. Our own diagnostics use
  public ints so they aren't `<private>`.
- **Sim auto-shuts-down** between tries; reboot with `xcrun simctl boot` + `bootstatus -b`.

## Files modified

Dusk layer (superproject, branch `visionos-stereo-depth`):
- `src/dusk/vision/StereoPresent.mm` — CompositorServices present loop: `cp_frame_query_drawables`,
  layered-aware eye blit, ARKit world-tracking start (main thread) + per-drawable device-anchor query,
  engine-thread hooks `stereo_engine_frame_begin/end`, the cross-thread eye/IOSurface state, diagnostics.
- `src/dusk/vision/StereoEngine.h` — **new**; plain-C++ engine-thread hook decls (no ObjC), included by
  `m_Do_main.cpp`.
- `src/dusk/vision/StereoBridge.{h,mm}` — `SharedEyeTexture` (IOSurface↔Dawn import, MTLSharedEvent
  fence) + thread-safe `latestEndAccessFence`.
- `src/dusk/vision/StereoPresent.h` — signatures (dropped the eye param; loop uses module-global eye).
- `src/dusk/vision/DuskVisionApp.swift` — SwiftUI `@main`: opens the `DuskStereo` ImmersiveSpace, logs
  the result; `dismissWindow` currently DISABLED (kept the launch window so the app stays foreground —
  re-enable once content shows).
- `src/m_Do/m_Do_main.cpp` — brackets both `aurora_end_frame()` call sites (launchUILoop + main01) with
  `dusk::vision::stereo_engine_frame_begin()/_end()`, guarded `#if TARGET_OS_VISION`.
- `CMakeLists.txt` — `if (VISIONOS)` block: link `-framework ARKit` (+ Metal/IOSurface/CompositorServices).
- `platforms/visionos/Info.plist.in` — `UIApplicationSupportsMultipleScenes=true` (needed to open the
  ImmersiveSpace alongside the window).
- `docs/stereo-spike-interop.md` — full session log (§9.10–§9.16).

Aurora submodule (`extern/aurora`, branch `visionos-stereo-depth`, HEAD `c61e9c1`; superproject
pin updated by this checkpoint):
- `lib/webgpu/gpu.{cpp,hpp}` — `set_stereo_capture_target` / `has_stereo_capture_target` /
  `record_stereo_capture_blit` + shared-texture (IOSurface/MTLSharedEvent) device-feature request.
- `lib/aurora.cpp` — `end_frame` blits the **composited present source** (RmlUi output when present,
  else the resolved game frame) into the stereo capture target, so menus aren't black.
- (Earlier on-branch: `lib/window.cpp` SDL main-thread init — committed previously.)

NOT committed intentionally: `.claude/` (local settings); the throwaway vendored-SDL build patches
under `build/<preset>/_deps/` (see CLAUDE.md "Throwaway SDL patches" — re-apply after a clean configure).

## Build / sign / install / run

Device (`build/visionos-default`):
```sh
cmake --build build/visionos-default
codesign --force --generate-entitlement-der \
  --sign FF90CB4DBFB4B583ACD140487A599825BFFB09AF \
  --entitlements /tmp/dusk_ent.plist build/visionos-default/Dusklight.app   # ent plist: see memory visionos-device-signing
codesign --verify --strict build/visionos-default/Dusklight.app
xcrun devicectl device install app --device 6303AA5D-AE95-5D40-BAEE-B2E8C4AFEC3E build/visionos-default/Dusklight.app
# Launch from the HEADSET Home View (devicectl process launch stalls on visionOS). Keep headset ON.
# Read logs in Console.app -> select "Apple Vision Pro von Daniel" -> filter "dusk::vision".
```
Sim (`build/visionos-sim-default`, UDID `B8CDFBCF-99D5-421F-A15E-6C82BC29BFB4`): `cmake --build`, then
`xcrun simctl install` + `launch ... --dvd <ABSOLUTE host path to rom.iso>` (relative paths fail
validation). Disc already at the sim app's `Documents/rom.iso`. Foreground with `open -a Simulator`.

Recipes/IDs in memory: `visionos-build-recipe`, `visionos-device-signing`, `visionos-device-anchor-required`,
`visionos-sdl-swift-workaround`.

## NEXT 3 STEPS (resume here)

1. **DONE (2026-05-31 23:1x): diagnostics uncapped + engine heartbeat added; built/signed/installed.**
   All `StereoPresent.mm` diagnostics are now periodic (`< 5 || %300`) and on NSLog (device-visible):
   `engine_frame_begin #N` (the key heartbeat — proves the engine thread reaches `aurora_end_frame`),
   `device anchor tracked=N`, `drawables=… eyeReady=N`, `blitted eye …`. Engine import logs
   `engine imported … ARMED` / `engine FAILED to import`. **AWAITING a headset-on device run + Console
   capture** to read these. Interpreting the next capture (filter `dusk::vision`):
   - **No `engine_frame_begin #…` at all** → the engine background thread isn't running its frame loop
     on device (the real bug). Then trace: does `dusk_vision_run_engine`→`aurora_main`→`game_main`
     reach `launchUILoop`/`main01`? Suspect the `dispatch_sync(main)` in `ensureWorldTracking`
     deadlocking/contending with the engine's own marshal-to-main SDL init.
   - **`engine_frame_begin` present but `pendingSurface=0` forever** → the present thread never
     published the IOSurface (look for `published …x… eye IOSurface`); check the present loop reached
     the publish path (needs a drawable with non-zero color tex).
   - **`pendingSurface=1` but `engineInit=0` / `engine FAILED to import`** → `SharedEyeTexture::init`
     (Dawn `ImportSharedTextureMemory`) fails on device → investigate that.
   - **`eyeReady=1` + `blitted eye …` but still black** → content IS flowing; problem is elsewhere
     (e.g. the captured frame itself empty, or sRGB/format). Different bug than expected.
2. **Find why the engine never feeds the eye on device.** Last device run showed `eyeReady=0` and no
   `blitted eye` line for 18 s, while the sim reaches `eyeReady=1` fast. So `stereo_engine_frame_begin`
   isn't importing the published IOSurface on device. Check: is the engine background thread actually
   running its frame loop on device (does it reach `launchUILoop` / `aurora_end_frame`)? Prime suspect:
   the `dispatch_sync(main)` added to `ensureWorldTracking` interacting with the engine's own
   marshal-to-main SDL init (a main-thread ordering/contention issue). Confirm the present thread
   published `g_pendingIOSurface`, then confirm the engine thread picks it up.
3. **Once eye content flows:** re-enable `dismissWindow(id: kLaunchWindowID)` in `DuskVisionApp.swift`
   (remove the "keep window" workaround) so the launch panel doesn't float in front; verify the title
   screen / game shows head-locked in the headset. Then begin true per-eye stereo: per-eye proj·view
   matrix injection + two-pass render + off-axis frusta + head pose at `presentationTime`
   (`STEREO.md` §5.1; current present is mono-into-both-eyes, identity pose).

## Caveats still open
- App backgrounds/world-tracking pauses if the headset comes off (expected). Present loop should also
  pause GPU submits when the layer state isn't `running` (saw "GPU work from background" when backgrounded).
- Eye IOSurface is single-buffered (possible cross-frame read/write tearing once content streams).
- This is Dan's **private fork**; the upstream "no AI-authored code" rule is waived here (memory
  `dusklight-fork-ai-code-ok`). Would still apply if upstreaming.
