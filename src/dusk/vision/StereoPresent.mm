// Dusk visionOS stereoscopic present: CompositorServices render loop + scene-activation seam.
// See StereoPresent.h. SCAFFOLD -- the render loop is meant to compile/iterate; the scene seam is
// sketched with TODOs. visionOS-only.
#include "dusk/vision/StereoPresent.h"

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#import <CompositorServices/CompositorServices.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "dusk/vision/StereoEntry.h"

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
}  // namespace

bool presentStereoFrame(cp_layer_renderer_t layerRenderer, SharedEyeTexture& eye) noexcept {
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

  cp_frame_start_submission(frame);
  cp_drawable_t drawable = cp_frame_query_drawable(frame);
  if (drawable == nullptr) {
    cp_frame_end_submission(frame);
    return true;
  }

  id<MTLTexture> srcTex = eye.metalTexture(device);

  id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
  commandBuffer.label = @"Dusk Stereo Present";

  // Wait on the Dawn->IOSurface blit fence (from SharedEyeTexture::endAccess) before reading the
  // eye texture, so we don't sample a half-written frame.
  id<MTLSharedEvent> eyeEvent = eye.lastEndAccessSharedEvent();
  if (eyeEvent != nil) {
    [commandBuffer encodeWaitForEvent:eyeEvent value:eye.lastEndAccessSignaledValue()];
  }
  // TODO(stereo): if eyeEvent is nil (no fence exported), fall back to a coarse sync -- e.g. ensure
  // the producing Dawn submission has completed on the CPU before this point.

  if (srcTex != nil) {
    const size_t viewCount = cp_drawable_get_view_count(drawable);
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Dusk Stereo Eye Blit";
    for (size_t i = 0; i < viewCount; ++i) {
      id<MTLTexture> dstTex = cp_drawable_get_color_texture(drawable, i);
      if (dstTex == nil) {
        continue;
      }
      // Scaffold: blit the same (mono) eye texture into both eye views. Clamp the copy to the
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
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
    [blit endEncoding];
  } else {
    NSLog(@"[dusk::vision] presentStereoFrame: eye MTLTexture unavailable");
  }

  cp_drawable_encode_present(drawable, commandBuffer);
  [commandBuffer commit];

  cp_frame_end_submission(frame);
  return true;
}

void runStereoPresentLoop(cp_layer_renderer_t layerRenderer, SharedEyeTexture* eye) noexcept {
  if (layerRenderer == nullptr || eye == nullptr) {
    return;
  }
  // Block until the compositor is running before the first frame.
  cp_layer_renderer_wait_until_running(layerRenderer);
  while (true) {
    const cp_layer_renderer_state state = cp_layer_renderer_get_state(layerRenderer);
    if (state == cp_layer_renderer_state_invalidated) {
      break;
    }
    if (!presentStereoFrame(layerRenderer, *eye)) {
      break;
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

  // ----------------------------------------------------------------------------------------------
  // SCAFFOLD SIMPLIFICATION: the present loop needs a SharedEyeTexture that aliases whatever
  // IOSurface the engine renders the resolved frame into. The current aurora submodule does NOT yet
  // expose a published "stereo capture target" the present side can look up, so instead of waiting on
  // one we allocate a placeholder IOSurface sized to the layer's drawable and import it. This makes
  // the loop compile, link, and run end-to-end against a (blank) eye texture. Wiring the engine's
  // real resolved frame into this IOSurface (e.g. via an aurora capture hook) is the next step.
  //
  // The placeholder is a fixed size; the present blit clamps to the overlapping region against the
  // drawable's actual color texture, so an exact match is not required for the scaffold. We wait
  // until the compositor is running before allocating (so the Aurora device has had time to come up).
  // ----------------------------------------------------------------------------------------------
  cp_layer_renderer_wait_until_running(layerRenderer);

  const uint32_t eyeW = 1920;
  const uint32_t eyeH = 1080;

  IOSurfaceRef surface = dusk::vision::createBGRA8IOSurface(eyeW, eyeH);
  if (surface == nullptr) {
    NSLog(@"[dusk::vision] dusk_vision_start_present: failed to allocate placeholder IOSurface");
    return;
  }

  static dusk::vision::SharedEyeTexture s_eye;  // Lives for process lifetime (scaffold).
  if (!s_eye.valid()) {
    if (!s_eye.init(surface, eyeW, eyeH)) {
      NSLog(@"[dusk::vision] dusk_vision_start_present: SharedEyeTexture init failed (Aurora device "
            @"not ready?). Present loop not started.");
      CFRelease(surface);
      return;
    }
  }
  CFRelease(surface);  // s_eye retained its own reference in init().

  dusk::vision::runStereoPresentLoop(layerRenderer, &s_eye);
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
