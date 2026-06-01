// Dusk visionOS head-tracked camera ("look around in the game").
//
// Feeds the Apple Vision Pro headset orientation into Twilight Princess's camera as an ADDITIVE
// look-offset: the game keeps driving the base camera (following Link); the head rotation is composed
// on top of the final view matrix just before it is handed to the renderer. 3DOF orientation only.
//
// Threading: the head pose is published from the CompositorServices PRESENT thread
// (StereoPresent.mm's attachDeviceAnchor) via setHeadTransform(); apply() runs on the ENGINE thread
// (the camera path). The two are serialized by an internal mutex.
//
// visionOS-only; the header is empty elsewhere and the call sites are guarded the same way.
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

namespace dusk::vision::headlook {

// PRESENT thread: publish the latest head world transform (the column-major simd_float4x4 from
// ar_device_anchor_get_origin_from_anchor_transform, passed as 16 floats). `tracked == false` is a
// no-op (we freeze on tracking loss). The first tracked pose also becomes the recenter reference.
void setHeadTransform(const float transform[16], bool tracked) noexcept;

// Capture the current head pose as the recenter reference, so the game's forward aligns with the
// user's current forward. (Auto-captured on the first tracked pose; call again for a manual recenter.)
void recenter() noexcept;

// ENGINE thread: compose the additive head-look rotation onto `viewMtx` in place, just before
// j3dSys.setViewMtx. No-op when the head-look setting is off, no tracked pose exists, or `suppressed`
// is true (the caller passes true when the camera is under scripted control -- cutscene / Z-lock-on).
// viewMtx is a GameCube Mtx (f32[3][4]); typed as float(*)[4] so this header needs no decomp includes.
void apply(float (*viewMtx)[4], bool suppressed) noexcept;

}  // namespace dusk::vision::headlook

#endif  // visionOS
