// Dusk visionOS stereoscopic present: CompositorServices render loop + scene-activation seam.
//
// SCAFFOLD. The CompositorServices render loop (runStereoPresentLoop) is intended to compile and to
// be iterated on against the simulator. The scene-activation seam (getting a cp_layer_renderer_t out
// of an ImmersiveSpace/CompositorLayer scene from the UIKit/SDL app) is only sketched -- see the
// extensive TODO in StereoPresent.mm. visionOS-only.
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#include "dusk/vision/StereoBridge.h"

#ifdef __OBJC__
#import <CompositorServices/CompositorServices.h>
#endif

namespace dusk::vision {

#ifdef __OBJC__
// Drive one full CompositorServices frame: query/wait frame, query drawable, iterate eye views, and
// for each view blit the shared eye texture's IOSurface-backed MTLTexture into the drawable's color
// texture, then encode-present. Returns false when the layer is no longer running (caller should stop
// the loop). Until the engine thread has imported the shared eye texture, it publishes a sized
// IOSurface for the engine and presents empty drawables.
//
// The shared eye texture is a module global fed by the engine thread (see StereoEngine.h); for the
// scaffold the same (mono) texture is blitted into every view.
bool presentStereoFrame(cp_layer_renderer_t layerRenderer) noexcept;

// Blocking render loop wrapper: spins presentStereoFrame() until the layer is invalidated. Intended
// to be run on a dedicated render thread owned by the immersive scene.
void runStereoPresentLoop(cp_layer_renderer_t layerRenderer) noexcept;
#endif

// Request that the immersive scene be created/activated. See StereoPresent.mm for the (currently
// unresolved) SwiftUI <-> UIKit/SDL seam. Safe to call from C++; currently a logged no-op stub.
void requestImmersiveSpace() noexcept;

}  // namespace dusk::vision

#endif  // visionOS
