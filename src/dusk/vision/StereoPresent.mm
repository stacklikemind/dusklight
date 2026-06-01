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
#include <cstring>

#include "dusk/vision/HeadLook.h"
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
    NSLog(@"[dusk::vision] world tracking unsupported; drawables will lack a device anchor");
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
  NSLog(@"[dusk::vision] ARKit world tracking session started on main thread");
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
    // Publish the head pose to the head-look camera hook (the engine thread reads it). Head-look only
    // consumes it when the in-game setting is on; otherwise this is a cheap, unused store.
    const simd_float4x4 headXform = ar_device_anchor_get_origin_from_anchor_transform(anchor);
    float headMtx[16];
    memcpy(headMtx, &headXform, sizeof(float) * 16);
    dusk::vision::headlook::setHeadTransform(headMtx, true);
  }
  static unsigned long s_anchorFrames = 0;
  const unsigned long anchorN = s_anchorFrames++;
  if (anchorN < 5 || (anchorN % 300) == 0) {
    NSLog(@"[dusk::vision] device anchor tracked=%d (frame #%lu)", ok ? 1 : 0, anchorN);
  }
  return ok;
}

// -----------------------------------------------------------------------------------------------
// Cross-thread Step-C state. The CompositorServices present thread sizes + allocates the shared
// IOSurfaces (it alone knows the drawable's per-eye texture dimensions); the engine thread imports
// them into Dawn and drives the per-frame shared-texture access. Ownership of each field by thread:
//   - g_eye[]:             Dawn side (init/begin/endAccess) ONLY on the engine thread; Metal side
//                          (metalTexture / latestEndAccessFence) ONLY on the present thread. The two
//                          sides touch disjoint members except the lock-guarded fence fields.
//   - g_pendingIOSurface[]: written once by the present thread, consumed once by the engine thread.
//   - g_eyeReady:          engine -> present handshake; release/acquire publishes the imported eyes.
//
// TRUE PER-EYE STEREO: two eyes (index 0 = LEFT logical eye, 1 = RIGHT). Aurora re-renders the
// recorded frame twice, patching the projection per eye, into g_eye[0]/g_eye[1]'s IOSurfaces; the
// present loop blits each into the matching physical drawable view (left/right decided from the
// per-view eye-offset sign). Both eye IOSurfaces are the same size (the per-eye color texture size).
// -----------------------------------------------------------------------------------------------
constexpr int kEyeCount = 2;  // [0] = left, [1] = right
SharedEyeTexture g_eye[kEyeCount];
std::atomic<IOSurfaceRef> g_pendingIOSurface[kEyeCount]{{nullptr}, {nullptr}};
std::atomic<uint32_t> g_pendingWidth{0};
std::atomic<uint32_t> g_pendingHeight{0};
std::atomic<bool> g_eyeReady{false};

// Engine-thread-only bookkeeping for the frame-begin/end bracket.
bool g_engineInitDone = false;
bool g_didBeginThisFrame[kEyeCount]{false, false};

// ---- TRUE-STEREO TUNABLES (adjust these; tuned on device) -------------------------------------
// kStereoEyeSep: horizontal eye separation / parallax in TP world units. The per-eye projection
// shift is B = -eyeSep * focalX, applied as +eyeSep to the right eye and -eyeSep to the left eye.
// TP's world scale is unknown a priori, so this is THE knob: larger = more pronounced depth (and
// eye strain); 0 = mono. Flip the sign mapping below if depth feels inverted (near/far swapped).
// kStereoConvergence: off-axis convergence shift (m0.z -= convergence); 0 = convergence at infinity.
// Start near 0 and raise slightly to pull the zero-parallax plane closer.
static constexpr float kStereoEyeSep = 0.5f;        // game units; small -- even 1.0 strained on device
// Per-eye NDC horizontal panel shift, applied OPPOSITE per eye (left +c, right -c) as a blit offset, to
// converge the flat panel so it fuses. ~0.25 found on device (the AVP per-eye projection is strongly
// off-axis, so a large shift is needed). This is the constant offset; eyeSep adds depth around it.
static constexpr float kStereoConvergence = 0.25f;

// On-device tuning: when 1, ignore kStereoEyeSep/kStereoConvergence and instead run a tuning sweep in
// stereo_engine_frame_begin() (a few seconds per stable step) so a value can be picked by eye in ONE run.
// Currently sweeps PANEL CONVERGENCE (a per-eye horizontal slide) to fuse the flat panel; set back to 0
// and bake the chosen value once dialed in. See stereo_engine_frame_begin().
#define STEREO_EYESEP_SWEEP 0
}  // namespace

// Publish (once) TWO IOSurfaces (left + right), each sized to the compositor drawable's per-eye color
// texture, so the engine thread can import them as Aurora's per-eye stereo render targets. Returns
// true once both surfaces are published (now or earlier). Present-thread only.
static bool publishEyeSurfaceIfNeeded(cp_drawable_t drawable) noexcept {
  if (g_pendingIOSurface[0].load(std::memory_order_acquire) != nullptr &&
      g_pendingIOSurface[1].load(std::memory_order_acquire) != nullptr) {
    return true;  // Already published; engine will import them.
  }
  id<MTLTexture> dst0 = cp_drawable_get_color_texture(drawable, 0);
  if (dst0 == nil || dst0.width == 0 || dst0.height == 0) {
    return false;
  }
  const uint32_t w = static_cast<uint32_t>(dst0.width);
  const uint32_t h = static_cast<uint32_t>(dst0.height);
  IOSurfaceRef left = createBGRA8IOSurface(w, h);
  IOSurfaceRef right = createBGRA8IOSurface(w, h);
  if (left == nullptr || right == nullptr) {
    if (left != nullptr) {
      CFRelease(left);
    }
    if (right != nullptr) {
      CFRelease(right);
    }
    return false;
  }
  g_pendingWidth.store(w, std::memory_order_relaxed);
  g_pendingHeight.store(h, std::memory_order_relaxed);
  // Hand the +1-retained surfaces to the engine thread (release-publish). The engine's
  // SharedEyeTexture::init CFRetains them; our +1 is intentionally leaked for the process-lifetime
  // scaffold rather than racing a CFRelease against the import. Publish right first so that once the
  // engine observes a non-null left[0] (its loop predicate), both are already visible.
  g_pendingIOSurface[1].store(right, std::memory_order_release);
  g_pendingIOSurface[0].store(left, std::memory_order_release);
  NSLog(@"[dusk::vision] published two %ux%u eye IOSurfaces (L+R) for engine import", w, h);
  return true;
}

// Map a physical drawable view to a logical eye index (0 = left, 1 = right) from the view's eye
// offset along x (cp_view_get_transform columns[3].x; left eye is the negative-x offset). Falls back
// to using the view index itself if the offset is ~0 (e.g. a single-view drawable). Present-thread.
static int logicalEyeForView(cp_drawable_t drawable, size_t viewIndex) noexcept {
  cp_view_t view = cp_drawable_get_view(drawable, viewIndex);
  const simd_float4x4 xform = cp_view_get_transform(view);
  const float offsetX = xform.columns[3].x;
  if (offsetX < -1e-5f) {
    return 0;  // left
  }
  if (offsetX > 1e-5f) {
    return 1;  // right
  }
  return static_cast<int>(viewIndex & 1);  // degenerate: fall back to view index
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

  // Periodic diagnostic (public ints -> visible un-redacted in Console.app). Confirms the drawable
  // structure AND how eyeReady evolves over time (capped logging hid the moment it flips). First few
  // frames, then every ~300.
  static unsigned long s_drawFrames = 0;
  const unsigned long drawN = s_drawFrames++;
  if (drawN < 5 || (drawN % 300) == 0) {
    cp_drawable_t d0 = drawables[0];
    const size_t texCount = cp_drawable_get_texture_count(d0);
    const size_t viewCount = cp_drawable_get_view_count(d0);
    id<MTLTexture> c0 = cp_drawable_get_color_texture(d0, 0);
    id<MTLTexture> z0 = cp_drawable_get_depth_texture(d0, 0);
    NSLog(@"[dusk::vision] drawables=%zu texCount=%zu viewCount=%zu color0=%lux%lu depth0=%s eyeReady=%d",
          drawableCount, texCount, viewCount,
          c0 ? (unsigned long)c0.width : 0UL, c0 ? (unsigned long)c0.height : 0UL,
          z0 ? "YES" : "nil", g_eyeReady.load(std::memory_order_acquire) ? 1 : 0);
    // Diagnostic for the black-screen-on-device bug: dump the color texture's actual format/usage/
    // sample-count/type plus the drawable's rasterization-rate-map count and state. A usage mask
    // WITHOUT MTLTextureUsageRenderTarget(0x4) would explain why a render-pass clear scans out black.
    if (c0 != nil) {
      NSLog(@"[dusk::vision] color0 fmt=%lu usage=0x%lx samples=%lu type=%lu rateMaps=%zu drawState=%d",
            (unsigned long)c0.pixelFormat, (unsigned long)c0.usage,
            (unsigned long)c0.sampleCount, (unsigned long)c0.textureType,
            cp_drawable_get_rasterization_rate_map_count(d0), (int)cp_drawable_get_state(d0));
    }
    // ---- TRUE-STEREO FOUNDATION (observation only; the live path is still mono into both eyes) ----
    // For each eye/view, read the data we'll feed into per-eye rendering: the device->view transform
    // (the eye offset; IPD is baked in by Apple), the ready-made per-eye projection
    // (cp_drawable_compute_projection, the non-deprecated replacement for cp_view_get_tangents), and
    // the authoritative view->(texture,slice) map. These numbers drive the convergence/world-scale
    // math for the two-pass render; logging them on-device first lets us design that math against real
    // values. simd_float4x4 is column-major: columns[3].xyz is the eye position (meters); the projection
    // asymmetry (off-axis convergence) shows up in columns[2].x / columns[2].y.
    for (size_t v = 0; v < viewCount && v < 2; ++v) {
      cp_view_t view = cp_drawable_get_view(d0, v);
      const simd_float4x4 eyeXform = cp_view_get_transform(view);
      const simd_float4x4 proj =
          cp_drawable_compute_projection(d0, cp_axis_direction_convention_right_up_back, v);
      const cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
      NSLog(@"[dusk::vision] view %zu eyeOffset=(%.4f,%.4f,%.4f)m tex=%zu slice=%zu "
            @"projXX=%.4f projYY=%.4f skewX=%.4f skewY=%.4f",
            v, eyeXform.columns[3].x, eyeXform.columns[3].y, eyeXform.columns[3].z,
            cp_view_texture_map_get_texture_index(tmap), cp_view_texture_map_get_slice_index(tmap),
            proj.columns[0].x, proj.columns[1].y, proj.columns[2].x, proj.columns[2].y);
    }
  }

  id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
  commandBuffer.label = @"Dusk Stereo Present";

  // Decisive black-screen diagnostic: log whether the present command buffer (clear + encode_present)
  // actually executes on the GPU. status=4 (Completed) + error=none => our GPU work succeeded and the
  // black screen is a COMPOSITOR/scene-display problem, not our rendering. status=5 (Error) => the
  // error string names the GPU failure. (MTLCommandBufferStatus: NotEnqueued0 Enqueued1 Committed2
  // Scheduled3 Completed4 Error5.) First few frames + every ~300.
  {
    static unsigned long s_cbFrames = 0;
    const unsigned long cbN = s_cbFrames++;
    if (cbN < 5 || (cbN % 300) == 0) {
      [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        NSLog(@"[dusk::vision] cmdbuf #%lu status=%ld error=%@", cbN, (long)cb.status,
              cb.error ? cb.error.localizedDescription : @"none");
      }];
    }
  }

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

  // ===================== DIAGNOSTIC BISECTION (toggle) =====================
  // Black-on-device, but the whole pipeline logs success. This isolates "does the present/compositor
  // path display ANYTHING on device" from "the content we hand it is invisible (black or alpha=0)".
  // When true: clear each eye slice to a solid OPAQUE color (red=view0, blue=view1) via a render pass,
  // bypassing the IOSurface entirely. If you SEE red/blue -> present+scene+per-eye mapping are good,
  // bug is the captured content/alpha. If still black -> the present/scene path itself isn't showing.
  // Set false to restore the real IOSurface eye blit.
  // RESOLVED (2026-06-01, device): the black screen was NEVER the color path -- it was a MISSING DEPTH
  // WRITE. visionOS reprojects every presented frame using the drawable's depth texture; a real AVP
  // scans out black for a frame whose depth wasn't written+stored (the sim is lenient). Once this clear
  // pass also clears+stores cp_drawable_get_depth_texture (see below), the forced red(L)/blue(R) showed
  // per-eye on device. Layout (dedicated vs layered) was a red herring -- both work once depth is
  // written. This force-clear stays as a kept diagnostic; flip true to re-verify the present path
  // independent of the engine/IOSurface. See docs/stereo-spike-interop.md §9.17-§9.19.
  static constexpr bool kForceEyeClearTest = false;
  if (kForceEyeClearTest) {
    for (size_t d = 0; d < drawableCount; ++d) {
      cp_drawable_t drawable = drawables[d];
      const size_t viewCount = cp_drawable_get_view_count(drawable);
      const size_t texCount = cp_drawable_get_texture_count(drawable);
      for (size_t view = 0; view < viewCount; ++view) {
        const size_t texIndex = (texCount >= viewCount) ? view : 0;
        const NSUInteger slice = (texCount >= viewCount) ? 0 : (NSUInteger)view;
        id<MTLTexture> dstTex = cp_drawable_get_color_texture(drawable, texIndex);
        if (dstTex == nil) {
          continue;
        }
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = dstTex;
        rp.colorAttachments[0].slice = slice;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor =
            (view == 0) ? MTLClearColorMake(1.0, 0.0, 0.0, 1.0)   // left eye: opaque red
                        : MTLClearColorMake(0.0, 0.0, 1.0, 1.0);  // right eye: opaque blue
        // visionOS's compositor reprojects every presented frame using the drawable's DEPTH texture.
        // A real device can blank a frame whose depth wasn't produced (the sim is lenient). We were
        // rendering color-only -> suspected cause of the all-black scanout. Attach + clear + STORE the
        // depth texture so the compositor has valid depth to reproject our flat clear.
        id<MTLTexture> dstDepth = cp_drawable_get_depth_texture(drawable, texIndex);
        if (dstDepth != nil) {
          rp.depthAttachment.texture = dstDepth;
          rp.depthAttachment.slice = slice;
          rp.depthAttachment.loadAction = MTLLoadActionClear;
          rp.depthAttachment.storeAction = MTLStoreActionStore;
          rp.depthAttachment.clearDepth = 1.0;
        }
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:rp];
        if (enc == nil) {
          static unsigned long s_nilEnc = 0;
          if ((s_nilEnc++ % 300) == 0) {
            NSLog(@"[dusk::vision] FORCE-CLEAR: NIL render encoder (view=%zu tex=%p) -- clear not issued!",
                  view, (__bridge void*)dstTex);
          }
          continue;
        }
        enc.label = @"Dusk Eye Clear Test";
        [enc endEncoding];
      }
    }
    static unsigned long s_clearFrames = 0;
    const unsigned long clearN = s_clearFrames++;
    if (clearN < 5 || (clearN % 300) == 0) {
      NSLog(@"[dusk::vision] FORCE-CLEAR test: red(L)/blue(R)+depth into eyes (frame #%lu)", clearN);
    }
    for (size_t i = 0; i < drawableCount; ++i) {
      attachDeviceAnchor(drawables[i]);
      cp_drawable_encode_present(drawables[i], commandBuffer);
    }
    [commandBuffer commit];
    cp_frame_end_submission(frame);
    return true;
  }
  // ========================= END DIAGNOSTIC =========================

  // Per-eye source textures: g_eye[0] = left, g_eye[1] = right (Aurora rendered each with a per-eye
  // projection shift). Both alias the IOSurfaces published earlier.
  id<MTLTexture> eyeTex[kEyeCount] = {g_eye[0].metalTexture(device), g_eye[1].metalTexture(device)};

  // Wait on each eye's Dawn->IOSurface blit fence (from SharedEyeTexture::endAccess, engine thread)
  // before reading that eye texture, so we don't sample a half-written frame. Event + value are
  // fetched together under a lock so we never wait on a value the event won't reach. One wait per
  // eye per command buffer covers every drawable/view blitted below.
  for (int eye = 0; eye < kEyeCount; ++eye) {
    id<MTLSharedEvent> eyeEvent = nil;
    uint64_t eyeValue = 0;
    if (g_eye[eye].latestEndAccessFence(&eyeEvent, &eyeValue) && eyeEvent != nil) {
      [commandBuffer encodeWaitForEvent:eyeEvent value:eyeValue];
    }
  }
  // TODO(stereo): if no fence was exported, fall back to a coarse sync -- e.g. ensure the producing
  // Dawn submission has completed on the CPU before this point.

  // REQUIRED on device: write+store each eye's DEPTH texture or the compositor scans out BLACK (the
  // simulator is lenient). The color comes from the blit below; depth has no source, so clear+store
  // it via a depth-only render pass per eye. Different textures from the blit -> no ordering hazard.
  for (size_t d = 0; d < drawableCount; ++d) {
    cp_drawable_t drawable = drawables[d];
    const size_t viewCount = cp_drawable_get_view_count(drawable);
    const size_t texCount = cp_drawable_get_texture_count(drawable);
    for (size_t view = 0; view < viewCount; ++view) {
      const size_t texIndex = (texCount >= viewCount) ? view : 0;
      const NSUInteger slice = (texCount >= viewCount) ? 0 : (NSUInteger)view;
      id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIndex);
      if (depthTex == nil) {
        continue;
      }
      MTLRenderPassDescriptor* dp = [MTLRenderPassDescriptor renderPassDescriptor];
      dp.depthAttachment.texture = depthTex;
      dp.depthAttachment.slice = slice;
      dp.depthAttachment.loadAction = MTLLoadActionClear;
      dp.depthAttachment.storeAction = MTLStoreActionStore;
      dp.depthAttachment.clearDepth = 1.0;
      id<MTLRenderCommandEncoder> denc = [commandBuffer renderCommandEncoderWithDescriptor:dp];
      [denc endEncoding];
    }
  }

  if (eyeTex[0] != nil && eyeTex[1] != nil) {
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Dusk Stereo Eye Blit";
    for (size_t d = 0; d < drawableCount; ++d) {
      cp_drawable_t drawable = drawables[d];
      const size_t viewCount = cp_drawable_get_view_count(drawable);
      const size_t texCount = cp_drawable_get_texture_count(drawable);
      for (size_t view = 0; view < viewCount; ++view) {
        // Two layouts: DEDICATED (texCount == viewCount) -> one texture per view, slice 0; LAYERED
        // (texCount == 1, viewCount > 1, as on the real device) -> a single 2D-array color texture
        // whose slice index IS the view index. Map view -> (texture, slice) for both cases.
        const size_t texIndex = (texCount >= viewCount) ? view : 0;
        const NSUInteger slice = (texCount >= viewCount) ? 0 : (NSUInteger)view;
        id<MTLTexture> dstTex = cp_drawable_get_color_texture(drawable, texIndex);
        if (dstTex == nil) {
          continue;
        }
        // TRUE STEREO: pick the eye source matching this physical view (left/right from the view's
        // eye-offset sign), so each eye gets its own per-eye-projected image. Clamp the copy to the
        // overlapping region so mismatched sizes don't trap.
        const int eye = logicalEyeForView(drawable, view);
        id<MTLTexture> srcTex = eyeTex[eye];
        if (srcTex == nil) {
          continue;
        }
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
    static unsigned long s_blitFrames = 0;
    const unsigned long blitN = s_blitFrames++;
    if (blitN < 5 || (blitN % 300) == 0) {
      NSLog(@"[dusk::vision] blitted L+R eyes (%lux%lu) into drawable views (frame #%lu)",
            (unsigned long)eyeTex[0].width, (unsigned long)eyeTex[0].height, blitN);
    }
  } else {
    static unsigned long s_noTexFrames = 0;
    if ((s_noTexFrames++ % 300) == 0) {
      NSLog(@"[dusk::vision] presentStereoFrame: eye MTLTexture unavailable");
    }
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
  // Heartbeat: proves the ENGINE thread is actually reaching aurora_end_frame on device. If this
  // never appears in Console.app, the engine frame loop isn't running -- the real bug. NSLog (not
  // fprintf/stderr) so it shows on device. First few frames, then every ~300.
  static unsigned long s_engineFrames = 0;
  const unsigned long engN = s_engineFrames++;
  if (engN < 5 || (engN % 300) == 0) {
    NSLog(@"[dusk::vision] engine_frame_begin #%lu: pendingSurface=%d engineInit=%d eyeReady=%d", engN,
          g_pendingIOSurface[0].load(std::memory_order_acquire) != nullptr ? 1 : 0,
          g_engineInitDone ? 1 : 0, g_eyeReady.load(std::memory_order_acquire) ? 1 : 0);
  }
  if (!g_engineInitDone) {
    IOSurfaceRef left = g_pendingIOSurface[0].load(std::memory_order_acquire);
    IOSurfaceRef right = g_pendingIOSurface[1].load(std::memory_order_acquire);
    if (left != nullptr && right != nullptr) {
      const uint32_t w = g_pendingWidth.load(std::memory_order_relaxed);
      const uint32_t h = g_pendingHeight.load(std::memory_order_relaxed);
      if (g_eye[0].init(left, w, h) && g_eye[1].init(right, w, h)) {
        // Arm Aurora's TRUE per-eye stereo targets AND publish readiness on the same (engine) thread
        // that records the eye replays, so has_stereo_eye_targets() and our BeginAccess can never
        // disagree mid-frame. Sign convention: left eye gets -kStereoEyeSep, right gets +kStereoEyeSep
        // (flip if depth feels inverted). Aurora applies B = -eyeSep * focalX as a per-draw clip.x
        // shift, leaving orthographic (HUD/2D) draws untouched.
        aurora::webgpu::set_stereo_eye_targets(g_eye[0].view(), g_eye[1].view(), w, h,
                                               /*eyeSepLeft=*/-kStereoEyeSep, /*convLeft=*/+kStereoConvergence,
                                               /*eyeSepRight=*/+kStereoEyeSep, /*convRight=*/-kStereoConvergence);
        g_engineInitDone = true;
        g_eyeReady.store(true, std::memory_order_release);
        NSLog(@"[dusk::vision] engine imported two %ux%u eye textures; TRUE stereo ARMED (eyeSep=%.2f conv=%.2f)",
              w, h, (double)kStereoEyeSep, (double)kStereoConvergence);
      } else {
        // Import failed: drop the pending surfaces so we don't retry every frame, and leave the eye
        // targets unset (the engine keeps presenting mono to its flat surface).
        g_pendingIOSurface[0].store(nullptr, std::memory_order_release);
        g_pendingIOSurface[1].store(nullptr, std::memory_order_release);
        NSLog(@"[dusk::vision] engine FAILED to import eye textures; stereo disabled");
      }
    }
  }
  // Open shared-texture access for both eyes this frame. Must precede aurora_end_frame(), which
  // records and submits the per-eye replays that write the shared textures.
  if (g_engineInitDone) {
#if STEREO_EYESEP_SWEEP
    // On-device PANEL CONVERGENCE sweep. The reported problem is a large CONSTANT inter-eye offset that
    // the eyeSep (depth-only) sweep couldn't budge -- i.e. the flat panel isn't fused. This sweep slides
    // the two eye images horizontally in OPPOSITE directions (a gross, unmistakable shift done in the eye
    // blit) while holding eyeSep at 0 (no scene parallax), so the goal is simply: find the step where the
    // image merges into ONE. kSweep is the per-eye NDC x-shift; left eye gets +c, right eye -c. Because
    // this shift happens in the blit that already fills the eyes, "no change at all" would mean the
    // per-eye path isn't reaching the display (a deeper bug) rather than a tuning miss. Once the fusing
    // step is found we lock that convergence and bring eyeSep back for depth. Set STEREO_EYESEP_SWEEP 0
    // and kStereoConvergence/kStereoEyeSep when dialed in.
    // Panel convergence is now LOCKED at kStereoConvergence (the flat panel fuses). Sweep eyeSep -- the
    // scene DEPTH parallax -- so the 3D amount can be picked by eye. Step 1 = 0 (flat, no depth); depth
    // grows each step. Report the comfortable step, where it becomes too much / strains, and whether
    // depth pops TOWARD you (correct) or sinks in wrong (inverted -> flip the eyeSep sign mapping).
    static const float kSweep[] = {0.0f, 1.0f, 2.0f, 4.0f, 6.0f, 9.0f, 12.0f};
    static const int kSweepN = static_cast<int>(sizeof(kSweep) / sizeof(kSweep[0]));
    static const unsigned long kHoldFrames = 90;  // ~3-4 s per step
    static unsigned long s_sweepFrame = 0;
    static int s_lastStep = -1;
    const int step = static_cast<int>((s_sweepFrame / kHoldFrames) % static_cast<unsigned long>(kSweepN));
    const float sep = kSweep[step];
    if (step != s_lastStep) {
      s_lastStep = step;
      NSLog(@"[dusk::vision] EYESEP SWEEP step %d/%d eyeSep=%.2f conv=%.2f (steps from 1; step 1 = flat)",
            step + 1, kSweepN, (double)sep, (double)kStereoConvergence);
    }
    ++s_sweepFrame;
    aurora::webgpu::set_stereo_eye_targets(g_eye[0].view(), g_eye[1].view(),
                                           g_pendingWidth.load(std::memory_order_relaxed),
                                           g_pendingHeight.load(std::memory_order_relaxed),
                                           /*eyeSepLeft=*/-sep, /*convLeft=*/+kStereoConvergence,
                                           /*eyeSepRight=*/+sep, /*convRight=*/-kStereoConvergence);
#endif
    g_didBeginThisFrame[0] = g_eye[0].beginAccess();
    g_didBeginThisFrame[1] = g_eye[1].beginAccess();
  }
}

void stereo_engine_frame_end() noexcept {
  for (int eye = 0; eye < kEyeCount; ++eye) {
    if (g_didBeginThisFrame[eye]) {
      g_eye[eye].endAccess();  // Exports the GPU-completion fence the present loop waits on.
      g_didBeginThisFrame[eye] = false;
    }
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
  NSLog(@"[dusk::vision] dusk_vision_start_present: entering CompositorServices present loop");
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
