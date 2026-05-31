// Dusk visionOS scene-activation seam: plain-C bridge between the SwiftUI @main app
// (DuskVisionApp.swift) and the existing C++ engine + CompositorServices present loop.
//
// This header is the Swift bridging header (imported via -import-objc-header). It deliberately uses
// only plain C types and an opaque pointer for the CompositorServices layer renderer so Swift can
// call it without C++ interop. visionOS-only; gated so other platforms see nothing.
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle for a CompositorServices `cp_layer_renderer_t`. On the Swift side a
// `LayerRenderer` (from the CompositorLayer closure) bridges to `cp_layer_renderer_t`, which is an
// Objective-C object pointer; we accept it here as a void* and cast back to cp_layer_renderer_t in
// the .mm implementation. Passing it as a raw pointer avoids requiring CompositorServices' C headers
// to be visible to the Swift bridging surface.
typedef void* DuskLayerRendererHandle;

// Runs the existing Dusk engine entry point (aurora_main -> DuskMain -> the blocking m_Do main
// loop). Intended to be invoked once, on a dedicated background thread spawned by the Swift app,
// because it blocks for the lifetime of the game. `argc`/`argv` are forwarded verbatim (the Swift
// app synthesizes them from CommandLine.arguments, or a minimal {"Dusklight", NULL}).
//
// Returns the engine's exit code when the loop finally returns.
int dusk_vision_run_engine(int argc, const char* const* argv);

// Hands a CompositorServices layer renderer (captured from the ImmersiveSpace's CompositorLayer
// closure) to the C++ present loop. Blocks for the lifetime of the immersive scene, so the Swift
// caller must invoke it on a dedicated thread/Task. The handle must outlive the call (it does: the
// CompositorLayer owns it for the duration of the closure).
//
// SCAFFOLD: the present loop needs a SharedEyeTexture that aliases the IOSurface registered as
// Aurora's stereo capture target. Until the engine has booted far enough to publish that capture
// target, this function waits (polling) for it; see the implementation for the exact simplification.
void dusk_vision_start_present(DuskLayerRendererHandle layerRenderer);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // visionOS
