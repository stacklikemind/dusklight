// Dusk visionOS stereoscopic present: CompositorServices render loop + scene-activation seam.
// See StereoPresent.h. SCAFFOLD -- the render loop is meant to compile/iterate; the scene seam is
// sketched with TODOs. visionOS-only.
#include "dusk/vision/StereoPresent.h"

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <cstdio>

#include "dusk/vision/StereoEngine.h"
#include "dusk/vision/StereoEntry.h"
#include "webgpu/gpu.hpp"  // aurora::webgpu::set_stereo_capture_target (extern/aurora/lib on include path)

// aurora_main(argc, argv) is Dusk's real engine entry (src/dusk/main.cpp's `int main` is renamed to
// aurora_main by aurora/main.h's `#define main aurora_main`). We call it directly from the engine
// shim below.
extern "C" int aurora_main(int argc, char** argv);

namespace dusk::vision {

namespace {
// One shared command queue for the present-side blits, created lazily from the layer's device.
id<MTLCommandQueue> g_presentQueue = nil;

id<MTLCommandQueue> ensureQueue(id<MTLDevice> device) {
  if (g_presentQueue == nil && device != nil) {
    g_presentQueue = [device newCommandQueue];
    g_presentQueue.label = @"Dusk Stereo Present Queue";
  }
  return g_presentQueue;
}

// ARKit world tracking for the per-frame device anchor (head pose). The real device REQUIRES every
// presented drawable to carry a device anchor -- without it the compositor drops the frame with
// "Presenting a drawable without a device anchor. This drawable won't be presented." (the simulator
// does not enforce this). Device pose / world tracking needs no user authorization in an immersive
// space. All of this runs on the present thread (the query is documented AR_MT_UNSAFE).
// ALL of these are process-lifetime statics on purpose. Previously the config + data-providers
// collection were locals released by ARC right after ar_session_run -- if run() doesn't retain them
// the world-tracking provider tears down, which matched the observed "reached running once, then
// never again" flakiness. Keep every ARKit object alive.
ar_session_t g_arSession = nil;
ar_world_tracking_provider_t g_worldProvider = nil;
ar_data_providers_t g_dataProviders = nil;
ar_world_tracking_configuration_t g_worldConfig = nil;

void ensureWorldTracking() {
  if (g_worldProvider != nil) {
    return;
  }
  if (!ar_world_tracking_provider_is_supported()) {
    fprintf(stderr, "[dusk::vision] world tracking unsupported; drawables will lack a device anchor\n");
    return;
  }
  // Start the ARKit session on the MAIN thread. ar_session_run kicks off an async authorization +
  // provider start-up handshake (XPC to arkitd) whose callbacks need a serviced run loop; started on
  // the bare present thread the provider stays stuck and every device-anchor query fails with
  // "the world tracking provider is running" == false. This matches how the rest of the visionOS
  // port marshals UIKit/SDL init to main.
  dispatch_sync(dispatch_get_main_queue(), ^{
    g_worldConfig = ar_world_tracking_configuration_create();
    g_worldProvider = ar_world_tracking_provider_create(g_worldConfig);
    g_dataProviders = ar_data_providers_create();
    ar_data_providers_add_data_provider(g_dataProviders, g_worldProvider);
    g_arSession = ar_session_create();
    ar_session_run(g_arSession, g_dataProviders);
  });
  fprintf(stderr, "[dusk::vision] ARKit world tracking session started on main thread\n");
}

// Attach a device anchor to the drawable so the compositor will present it. The compositor drops any
// drawable presented WITHOUT an anchor. We ALWAYS attach one: the real predicted head pose when world
// tracking is running, otherwise a freshly-created (identity) anchor that gives a head-LOCKED image
// instead of a dropped (black) frame. This breaks the chicken-and-egg where nothing renders until
// tracking is up -> user looks away -> app backgrounds -> tracking never stabilizes. Once tracking
// comes up the same code path switches to the real (head-tracked) anchor automatically.
// Returns true iff a VALID, TRACKED device anchor was attached. The compositor rejects an untracked
// (identity) anchor with "device anchor has invalid tracking. This drawable won't be presented", so a
// fabricated fallback is useless -- only a real tracked anchor counts. Returns false until world
// tracking is up (caller should then skip presenting this drawable; it would be dropped anyway).
bool attachDeviceAnchor(cp_drawable_t drawable) {
  if (g_worldProvider == nil ||
      ar_data_provider_get_state(g_worldProvider) != ar_data_provider_state_running) {
    return false;
  }
  cp_frame_timing_t timing = cp_drawable_get_frame_timing(drawable);
  const CFTimeInterval presentTime =
      cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(timing));
  ar_device_anchor_t anchor = ar_device_anchor_create();
  const bool ok = ar_world_tracking_provider_query_device_anchor_at_timestamp(
                      g_worldProvider, presentTime, anchor) == ar_device_anchor_query_status_success &&
                  ar_device_anchor_is_tracked(anchor);
  if (ok) {
    cp_drawable_set_device_anchor(drawable, anchor);
  }
  static int s_anchorLogged = 0;
  if (s_anchorLogged < 6) {
    ++s_anchorLogged;
    NSLog(@"[dusk::vision] device anchor tracked=%d", ok ? 1 : 0);
  }
  return ok;
}

// -----------------------------------------------------------------------------------------------
// Cross-thread Step-C state. The CompositorServices present thread sizes + allocates the shared
// IOSurface (it alone knows the drawable's per-eye texture dimensions); the engine thread imports it
// into Dawn and drives the per-frame shared-texture access. Ownership of each field by thread:
//   - g_eye:               Dawn side (init/begin/endAccess) ONLY on the engine thread; Metal side
//                          (metalTexture / latestEndAccessFence) ONLY on the present thread. The two
//                          sides touch disjoint members except the lock-guarded fence fields.
//   - g_pendingIOSurface:  written once by the present thread, consumed once by the engine thread.
//   - g_eyeReady:          engine -> present handshake; release/acquire publishes the imported eye.
// -----------------------------------------------------------------------------------------------
SharedEyeTexture g_eye;
std::atomic<IOSurfaceRef> g_pendingIOSurface{nullptr};
std::atomic<uint32_t> g_pendingWidth{0};
std::atomic<uint32_t> g_pendingHeight{0};
std::atomic<bool> g_eyeReady{false};

// Engine-thread-only bookkeeping for the frame-begin/end bracket.
bool g_engineInitDone = false;
bool g_didBeginThisFrame = false;
}  // namespace

// Publish (once) an IOSurface sized to the compositor drawable's per-eye color texture so the engine
// thread can import it as Aurora's stereo capture target. Returns true once a surface is published
// (now or earlier). Present-thread only.
static bool publishEyeSurfaceIfNeeded(cp_drawable_t drawable) noexcept {
  if (g_pendingIOSurface.load(std::memory_order_acquire) != nullptr) {
    return true;  // Already published; engine will import it.
  }
  id<MTLTexture> dst0 = cp_drawable_get_color_texture(drawable, 0);
  if (dst0 == nil || dst0.width == 0 || dst0.height == 0) {
    return false;
  }
  const uint32_t w = static_cast<uint32_t>(dst0.width);
  const uint32_t h = static_cast<uint32_t>(dst0.height);
  IOSurfaceRef surface = createBGRA8IOSurface(w, h);
  if (surface == nullptr) {
    return false;
  }
  g_pendingWidth.store(w, std::memory_order_relaxed);
  g_pendingHeight.store(h, std::memory_order_relaxed);
  // Hand the +1-retained surface to the engine thread (release-publish). The engine's
  // SharedEyeTexture::init CFRetains it; our +1 is intentionally leaked for the process-lifetime
  // scaffold rather than racing a CFRelease against the import.
  g_pendingIOSurface.store(surface, std::memory_order_release);
  fprintf(stderr, "[dusk::vision] published %ux%u eye IOSurface for engine import\n", w, h);
  return true;
}

bool presentStereoFrame(cp_layer_renderer_t layerRenderer) noexcept {
  if (layerRenderer == nullptr) {
    return false;
  }

  const cp_layer_renderer_state state = cp_layer_renderer_get_state(layerRenderer);
  if (state == cp_layer_renderer_state_invalidated) {
    return false;
  }
  if (state == cp_layer_renderer_state_paused) {
    // Block until the system resumes the layer (or invalidates it).
    cp_layer_renderer_wait_until_running(layerRenderer);
    return cp_layer_renderer_get_state(layerRenderer) != cp_layer_renderer_state_invalidated;
  }

  id<MTLDevice> device = cp_layer_renderer_get_device(layerRenderer);
  id<MTLCommandQueue> queue = ensureQueue(device);
  if (device == nil || queue == nil) {
    return true;
  }

  cp_frame_t frame = cp_layer_renderer_query_next_frame(layerRenderer);
  if (frame == nullptr) {
    return true;  // No frame available this iteration.
  }

  // Update phase: this is where head-pose-dependent CPU work belongs.
  cp_frame_start_update(frame);
  // TODO(stereo): query the predicted device anchor via ARKit
  // (ar_world_tracking_provider_query_device_anchor_at_timestamp at
  //  cp_frame_timing_get_presentation_time(timing)) and feed the per-eye view matrices into the
  // game's projection. For the scaffold we render whatever the game already produced (identity pose).
  cp_frame_end_update(frame);

  // Predict this frame's timing and wait until the compositor's optimal input time before encoding.
  // This timing handshake is part of the CompositorServices per-frame contract: the real device
  // compositor REQUIRES it and aborts in cp_frame_end_submission (BUG_IN_CLIENT) without it (the
  // simulator is lenient). Must be queried before cp_frame_query_drawable (see frame.h).
  cp_frame_timing_t timing = cp_frame_predict_timing(frame);
  if (timing != nullptr) {
    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
  }

  cp_frame_start_submission(frame);

  // Acquire the frame's drawables. The immersive scene is a visionOS-26 CompositorLayer, so the
  // compositor expects the array-based cp_frame_query_drawables path; the deprecated single
  // cp_frame_query_drawable (visionOS 1.0, deprecated in 26.0) leaves the frame's drawable state
  // unsatisfied and the real device aborts in cp_frame_end_submission (BUG_IN_CLIENT) -- the
  // simulator tolerates it. Normally there is exactly one (built-in) drawable; an additional
  // "capture" drawable can appear during high-quality recording.
  cp_drawable_t drawables[4];
  size_t drawableCount = 0;
  if (__builtin_available(visionOS 26.0, *)) {
    cp_drawable_array_t arr = cp_frame_query_drawables(frame);
    const size_t n = cp_drawable_array_get_count(arr);
    if (n == 0) {
      // Frame was cancelled (no drawables) -- discard it.
      cp_frame_end_submission(frame);
      return true;
    }
    for (size_t i = 0; i < n && drawableCount < 4; ++i) {
      cp_drawable_t d = cp_drawable_array_get_drawable(arr, i);
      if (d != nullptr) {
        drawables[drawableCount++] = d;
      }
    }
  } else {
    cp_drawable_t d = cp_frame_query_drawable(frame);
    if (d != nullptr) {
      drawables[drawableCount++] = d;
    }
  }
  if (drawableCount == 0) {
    cp_frame_end_submission(frame);
    return true;
  }

  // One-shot diagnostic (public ints -> visible un-redacted in Console.app). Confirms the drawable
  // structure on device, especially whether a depth texture must be written before present.
  static int s_drawLogged = 0;
  if (s_drawLogged < 3) {
    ++s_drawLogged;
    cp_drawable_t d0 = drawables[0];
    const size_t texCount = cp_drawable_get_texture_count(d0);
    const size_t viewCount = cp_drawable_get_view_count(d0);
    id<MTLTexture> c0 = cp_drawable_get_color_texture(d0, 0);
    id<MTLTexture> z0 = cp_drawable_get_depth_texture(d0, 0);
    NSLog(@"[dusk::vision] drawables=%zu texCount=%zu viewCount=%zu color0=%lux%lu depth0=%s eyeReady=%d",
          drawableCount, texCount, viewCount,
          c0 ? (unsigned long)c0.width : 0UL, c0 ? (unsigned long)c0.height : 0UL,
          z0 ? "YES" : "nil", g_eyeReady.load(std::memory_order_acquire) ? 1 : 0);
  }

  id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
  commandBuffer.label = @"Dusk Stereo Present";

  if (!g_eyeReady.load(std::memory_order_acquire)) {
    // The engine hasn't imported the shared eye texture yet. Publish a correctly-sized IOSurface
    // (from the primary drawable) for it to pick up, and present the (empty) drawables this iteration
    // so the compositor keeps ticking.
    publishEyeSurfaceIfNeeded(drawables[0]);
    // CONTRACT: after query_drawables + start_submission you MUST encode_present every drawable and
    // commit before end_submission, or cp_frame_end_submission aborts (BUG IN CLIENT). attachDeviceAnchor
    // only sets an anchor once tracking is up; until then the compositor itself drops the frame
    // ("device anchor has invalid tracking") -- that's a no-op, NOT a crash. So always present + commit.
    for (size_t i = 0; i < drawableCount; ++i) {
      attachDeviceAnchor(drawables[i]);
      cp_drawable_encode_present(drawables[i], commandBuffer);
    }
    [commandBuffer commit];
    cp_frame_end_submission(frame);
    return true;
  }

  id<MTLTexture> srcTex = g_eye.metalTexture(device);

  // Wait on the Dawn->IOSurface blit fence (from SharedEyeTexture::endAccess, engine thread) before
  // reading the eye texture, so we don't sample a half-written frame. Event + value are fetched
  // together under a lock so we never wait on a value the event won't reach. One wait per command
  // buffer covers every drawable/view blitted below.
  id<MTLSharedEvent> eyeEvent = nil;
  uint64_t eyeValue = 0;
  if (g_eye.latestEndAccessFence(&eyeEvent, &eyeValue) && eyeEvent != nil) {
    [commandBuffer encodeWaitForEvent:eyeEvent value:eyeValue];
  }
  // TODO(stereo): if no fence was exported, fall back to a coarse sync -- e.g. ensure the producing
  // Dawn submission has completed on the CPU before this point.

  if (srcTex != nil) {
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Dusk Stereo Eye Blit";
    for (size_t d = 0; d < drawableCount; ++d) {
      cp_drawable_t drawable = drawables[d];
      const size_t viewCount = cp_drawable_get_view_count(drawable);
      const size_t texCount = cp_drawable_get_texture_count(drawable);
      for (size_t view = 0; view < viewCount; ++view) {
        // Two layouts: DEDICATED (texCount == viewCount) -> one texture per view, slice 0; LAYERED
        // (texCount == 1, viewCount > 1, as on the real device) -> a single 2D-array color texture
        // whose slice index IS the view index. Blitting only slice 0 (the old code) left the right
        // eye black on device. Map view -> (texture, slice) for both cases.
        const size_t texIndex = (texCount >= viewCount) ? view : 0;
        const NSUInteger slice = (texCount >= viewCount) ? 0 : (NSUInteger)view;
        id<MTLTexture> dstTex = cp_drawable_get_color_texture(drawable, texIndex);
        if (dstTex == nil) {
          continue;
        }
        // Scaffold: blit the same (mono) eye texture into every eye view. Clamp the copy to the
        // overlapping region so mismatched sizes don't trap.
        // TODO(stereo): render/import a distinct texture per eye for true stereo separation.
        const NSUInteger w = MIN(srcTex.width, dstTex.width);
        const NSUInteger h = MIN(srcTex.height, dstTex.height);
        [blit copyFromTexture:srcTex
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(w, h, 1)
                    toTexture:dstTex
             destinationSlice:slice
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
      }
    }
    [blit endEncoding];
    static int s_blitLogged = 0;
    if (s_blitLogged < 2) {
      ++s_blitLogged;
      NSLog(@"[dusk::vision] blitted eye %lux%lu into drawable views",
            (unsigned long)srcTex.width, (unsigned long)srcTex.height);
    }
  } else {
    NSLog(@"[dusk::vision] presentStereoFrame: eye MTLTexture unavailable");
  }

  // Always encode_present + commit (CompositorServices contract; skipping aborts end_submission).
  // Frames without a tracked anchor are dropped by the compositor itself, harmlessly.
  for (size_t i = 0; i < drawableCount; ++i) {
    attachDeviceAnchor(drawables[i]);
    cp_drawable_encode_present(drawables[i], commandBuffer);
  }
  [commandBuffer commit];

  cp_frame_end_submission(frame);
  return true;
}

void runStereoPresentLoop(cp_layer_renderer_t layerRenderer) noexcept {
  if (layerRenderer == nullptr) {
    return;
  }
  // Block until the compositor is running before the first frame.
  cp_layer_renderer_wait_until_running(layerRenderer);
  while (true) {
    const cp_layer_renderer_state state = cp_layer_renderer_get_state(layerRenderer);
    if (state == cp_layer_renderer_state_invalidated) {
      break;
    }
    if (!presentStereoFrame(layerRenderer)) {
      break;
    }
  }
}

// ----------------------------------------------------------------------------------------------
// Engine-thread hooks (declared in StereoEngine.h). Called from src/m_Do/m_Do_main.cpp bracketing
// aurora_end_frame(). All Dawn-device work (import, BeginAccess/EndAccess) lives here because the
// Dawn device is engine-thread-only; see StereoEngine.h for the full rationale.
// ----------------------------------------------------------------------------------------------
void stereo_engine_frame_begin() noexcept {
  if (!g_engineInitDone) {
    IOSurfaceRef surface = g_pendingIOSurface.load(std::memory_order_acquire);
    if (surface != nullptr) {
      const uint32_t w = g_pendingWidth.load(std::memory_order_relaxed);
      const uint32_t h = g_pendingHeight.load(std::memory_order_relaxed);
      if (g_eye.init(surface, w, h)) {
        // Arm Aurora's capture target AND publish readiness on the same (engine) thread that records
        // the blit, so has_stereo_capture_target() and our BeginAccess can never disagree mid-frame.
        aurora::webgpu::set_stereo_capture_target(g_eye.view(), w, h);
        g_engineInitDone = true;
        g_eyeReady.store(true, std::memory_order_release);
        fprintf(stderr, "[dusk::vision] engine imported %ux%u eye texture; stereo capture armed\n", w,
                h);
      } else {
        // Import failed: drop the pending surface so we don't retry every frame, and leave the
        // capture target unset (the engine keeps presenting mono to its flat surface).
        g_pendingIOSurface.store(nullptr, std::memory_order_release);
        fprintf(stderr, "[dusk::vision] engine failed to import eye texture; stereo present disabled\n");
      }
    }
  }
  // Open shared-texture access for this frame. Must precede aurora_end_frame(), which records and
  // submits the capture blit that uses the shared texture.
  g_didBeginThisFrame = g_engineInitDone && g_eye.beginAccess();
}

void stereo_engine_frame_end() noexcept {
  if (g_didBeginThisFrame) {
    g_eye.endAccess();  // Exports the GPU-completion fence the present loop waits on.
    g_didBeginThisFrame = false;
  }
}

void requestImmersiveSpace() noexcept {
  // ============================ SCENE-ACTIVATION SEAM (UNRESOLVED) ============================
  // CompositorServices immersive rendering requires a cp_layer_renderer_t, which the system only
  // vends through a SwiftUI ImmersiveSpace that hosts a `CompositorLayer` (Swift:
  //   ImmersiveSpace(id: "dusk") { CompositorLayer(configuration: ...) { layerRenderer in ... } }
  // ). There is no pure C / UIKit / Objective-C API to construct a cp_layer_renderer_t directly.
  //
  // Dusklight runs as a UIKit app under SDL (SDL provides +[SDLUIKitDelegate getAppDelegateClassName]
  // as the override seam). The intended approach:
  //   1. A Dusk category overrides +[SDLUIKitDelegate getAppDelegateClassName] to return a Dusk
  //      delegate subclass (see DuskVisionAppDelegate below).
  //   2. That delegate (or an injected SwiftUI App/scene) declares an ImmersiveSpace whose
  //      CompositorLayer closure receives the cp_layer_renderer_t and hands it (plus a
  //      SharedEyeTexture wrapping the IOSurface registered with
  //      aurora::webgpu::set_stereo_capture_target) to runStereoPresentLoop() on a render thread.
  //   3. The delegate calls -[UIApplication ...]/openImmersiveSpace(id:) to activate it.
  //
  // OPEN PROBLEM: bridging a SwiftUI ImmersiveSpace into a UIKit/SDL-driven app cannot be made to
  // compile cleanly here without (a) adding a Swift compilation unit to the build and a Swift<->C++
  // bridging surface, and/or (b) restructuring app startup so a SwiftUI `App`/`Scene` owns the
  // window the way SDL currently does. Both are significant, uncertain changes. They are deliberately
  // NOT attempted in this scaffold. Until then, this is a logged no-op so the loop can be driven
  // manually in testing by feeding runStereoPresentLoop a cp_layer_renderer_t obtained elsewhere.
  NSLog(@"[dusk::vision] requestImmersiveSpace: scene-activation seam not yet wired (see "
        @"StereoPresent.mm). CompositorLayer must be hosted by a SwiftUI ImmersiveSpace.");
}

}  // namespace dusk::vision

// =============================================================================================
// Scene-activation seam: plain-C entry points called from DuskVisionApp.swift (declared in
// StereoEntry.h). These are the bridge between the SwiftUI @main app and the existing C++ engine +
// CompositorServices present loop.
// =============================================================================================

extern "C" int dusk_vision_run_engine(int argc, const char* const* argv) {
  // aurora_main takes (int, char**). The Swift side owns the argv storage for the duration of this
  // call, so the const_cast is safe (aurora/SDL do not mutate argv contents in practice).
  return aurora_main(argc, const_cast<char**>(argv));
}

extern "C" void dusk_vision_start_present(DuskLayerRendererHandle layerRendererHandle) {
  if (layerRendererHandle == nullptr) {
    NSLog(@"[dusk::vision] dusk_vision_start_present: null layer renderer handle");
    return;
  }
  // The Swift side passed the CompositorServices LayerRenderer as an unretained opaque pointer; it
  // bridges to cp_layer_renderer_t (an Objective-C object pointer).
  cp_layer_renderer_t layerRenderer = (__bridge cp_layer_renderer_t)layerRendererHandle;

  // Step C wiring: the present loop no longer allocates a blank placeholder. Instead it sizes and
  // publishes an IOSurface to the engine thread on the first frame (it alone knows the drawable's
  // per-eye dimensions); the engine imports that surface as Aurora's stereo capture target (see
  // stereo_engine_frame_begin) so the resolved game frame is blitted into it, and the loop then
  // presents that real frame into both eyes. Until the engine signals readiness, the loop presents
  // empty drawables (brief black) -- see presentStereoFrame().
  fprintf(stderr, "[dusk::vision] dusk_vision_start_present: entering CompositorServices present loop\n");
  // Start ARKit world tracking on this (present) thread so each drawable can carry a device anchor;
  // the device compositor drops anchorless drawables.
  dusk::vision::ensureWorldTracking();
  dusk::vision::runStereoPresentLoop(layerRenderer);
}

// ---------------------------------------------------------------------------------------------
// SDL delegate override skeleton.
//
// This is the documented SDL seam: an app provides a category on SDLUIKitDelegate overriding
// +getAppDelegateClassName to return its own delegate. Enabling it requires SDL's UIKit delegate
// headers on the include path; since reaching into vendored SDL internals here is out of scope (and
// the SwiftUI ImmersiveSpace seam above is the real blocker), the override is left commented as a
// precise skeleton rather than active code.
//
// @interface DuskVisionAppDelegate : SDLUIKitDelegate
// @end
// @implementation DuskVisionAppDelegate
// - (BOOL)application:(UIApplication *)application
//     didFinishLaunchingWithOptions:(NSDictionary *)opts {
//   BOOL r = [super application:application didFinishLaunchingWithOptions:opts];
//   dusk::vision::requestImmersiveSpace();  // -> openImmersiveSpace(id:) once the Swift scene exists
//   return r;
// }
// @end
//
// @interface SDLUIKitDelegate (DuskVision)
// @end
// @implementation SDLUIKitDelegate (DuskVision)
// + (NSString *)getAppDelegateClassName { return @"DuskVisionAppDelegate"; }
// @end
// ---------------------------------------------------------------------------------------------

#endif  // visionOS
