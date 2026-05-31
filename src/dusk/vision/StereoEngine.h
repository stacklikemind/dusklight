// Dusk visionOS stereoscopic present: engine-thread hooks.
//
// These two functions are called from the engine's frame loop (src/m_Do/m_Do_main.cpp), bracketing
// aurora_end_frame(). They live here (a plain C++ header, no Objective-C / Metal types) so the game
// translation unit can include them without pulling in CompositorServices/Metal. The implementation
// is in StereoPresent.mm.
//
// Why the engine thread: SharedEyeTexture::init / beginAccess / endAccess all drive Aurora's Dawn
// device, which is NOT thread-safe and is otherwise used only on the engine thread. So the Dawn-side
// import + per-frame shared-texture access must run here, serialized with Aurora's queue submit --
// not on the CompositorServices present thread (which does only Metal-side work).
//
// visionOS-only; compiles to nothing elsewhere.
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

namespace dusk::vision {

// Call immediately BEFORE aurora_end_frame(). The first time the present thread has published an
// IOSurface (sized to the compositor drawable), this performs the one-time Dawn import
// (SharedEyeTexture::init) and arms Aurora's stereo capture target so end_frame blits the resolved
// frame into the shared eye texture. Then, every frame the target is armed, it opens shared-texture
// access (BeginAccess) so the blit Aurora records is valid. No-op until a surface is published.
void stereo_engine_frame_begin() noexcept;

// Call immediately AFTER aurora_end_frame(). Closes shared-texture access (EndAccess), which exports
// the GPU-completion fence the present loop waits on before reading the eye texture. Paired with
// stereo_engine_frame_begin(); a no-op if that did not open access this frame.
void stereo_engine_frame_end() noexcept;

}  // namespace dusk::vision

#endif  // visionOS
