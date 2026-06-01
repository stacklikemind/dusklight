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
// Call at FRAME START (before the game's camera/draw runs for the frame). Snapshots the present
// thread's latest tracked head anchor as this frame's render pose and feeds it to the head-look camera
// hook, so the rendered camera and the drawable's device anchor use the same pose -- letting the
// compositor reproject head motion to the live display pose (smooth 90Hz head-look). No-op until a
// tracked anchor exists / off visionOS.
void stereo_engine_latch_head_pose() noexcept;

// Engine thread: mirror game.visionWorldLockedScreen into the present thread (which can't read settings).
// true = world-locked screen (a quad fixed in the room, compositor-reprojected); false = legacy
// face-locked panel (eyes blitted fullscreen). Call each frame from the game loop. Default true.
void stereo_set_world_locked(bool worldLocked) noexcept;

void stereo_engine_frame_begin() noexcept;

// Call immediately AFTER aurora_end_frame(). Closes shared-texture access (EndAccess), which exports
// the GPU-completion fence the present loop waits on before reading the eye texture. Paired with
// stereo_engine_frame_begin(); a no-op if that did not open access this frame.
void stereo_engine_frame_end() noexcept;

}  // namespace dusk::vision

#endif  // visionOS
