// Dusk visionOS head-tracked camera ("look around in the game"). See HeadLook.h.
//
// Plain C++ (not ObjC++) on purpose: it includes the decomp/Dusk headers (m_Do_mtx.h, settings.h)
// which compile cleanly in a normal C++ TU with the game PCH; `simd` and `os_log` are C-compatible.
#include "dusk/vision/HeadLook.h"

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#include <os/log.h>
#include <simd/simd.h>

#include <cmath>
#include <cstring>
#include <mutex>

#include "dusk/settings.h"
#include "m_Do/m_Do_mtx.h"  // Mtx ops (mDoMtx_YrotS/XrotM, cMtx_concat, cMtx_copy), s16

namespace dusk::vision::headlook {
namespace {

// ---- On-device tuning knobs (sign/axis are unknown until tested on hardware) -------------------
// If head-look goes the wrong way, flip the matching sign. kLookScale 1.0 == 1:1 head->camera.
constexpr float kYawSign = 1.0f;      // head turn right -> camera turn right (flip if inverted)
constexpr float kPitchSign = -1.0f;   // head look up -> camera look up (flipped: device was inverted)
constexpr float kLookScale = 1.0f;    // overall gain
constexpr bool kEnablePitch = true;   // set false to restrict to yaw-only while tuning
// ------------------------------------------------------------------------------------------------

std::mutex g_mutex;
simd_float4x4 g_current;    // head->world (ARKit origin-from-anchor)
simd_float4x4 g_reference;  // recenter reference (head->world at recenter)
bool g_haveCurrent = false;
bool g_haveReference = false;

simd_float4x4 matFromFloats(const float m[16]) noexcept {
  simd_float4x4 r;
  std::memcpy(&r, m, sizeof(float) * 16);
  return r;
}

constexpr float kPi = 3.14159265358979323846f;
constexpr float kRadToS16 = 32768.0f / kPi;  // GameCube angle units: 0x8000 == pi

}  // namespace

void setHeadTransform(const float transform[16], bool tracked) noexcept {
  if (!tracked || transform == nullptr) {
    return;  // freeze on tracking loss (keep last good pose)
  }
  std::lock_guard<std::mutex> lock(g_mutex);
  g_current = matFromFloats(transform);
  g_haveCurrent = true;
  if (!g_haveReference) {
    g_reference = g_current;  // first tracked pose defines "forward"
    g_haveReference = true;
  }
}

void recenter() noexcept {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_haveCurrent) {
    g_reference = g_current;
    g_haveReference = true;
  }
}

void apply(float (*viewMtx)[4], bool suppressed) noexcept {  // viewMtx is a GameCube Mtx (f32[3][4])
  if (suppressed) {
    return;  // scripted camera (cutscene / Z-lock-on) -- leave the game's camera untouched
  }
  if (!dusk::getSettings().game.visionHeadLook.getValue()) {
    return;
  }

  simd_float4x4 cur, ref;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_haveCurrent || !g_haveReference) {
      return;
    }
    cur = g_current;
    ref = g_reference;
  }

  // Head rotation relative to the recenter reference, expressed in the reference frame.
  const simd_float4x4 rel = simd_mul(simd_inverse(ref), cur);
  // ARKit cameras look down -Z; rel.columns[2] is the head's +Z basis in the reference frame.
  const simd_float3 fwd = -simd_make_float3(rel.columns[2].x, rel.columns[2].y, rel.columns[2].z);

  float yaw = std::atan2(fwd.x, -fwd.z);                              // about world up (Y)
  float pitch = std::asin(std::fmax(-1.0f, std::fmin(1.0f, fwd.y)));  // about right (X)
  yaw *= kYawSign * kLookScale;
  pitch *= kPitchSign * kLookScale;

  const s16 yawS = static_cast<s16>(yaw * kRadToS16);
  const s16 pitchS = kEnablePitch ? static_cast<s16>(pitch * kRadToS16) : 0;

  // Build the additive head rotation (yaw about Y, then pitch about X) and compose it onto the view
  // matrix in view space (pre-multiply). Output via a temp to avoid any in-place-aliasing assumption.
  Mtx headRot;
  mDoMtx_YrotS(headRot, yawS);
  mDoMtx_XrotM(headRot, pitchS);
  Mtx out;
  cMtx_concat(headRot, viewMtx, out);
  cMtx_copy(out, viewMtx);

  static unsigned long s_diag = 0;
  if ((s_diag++ % 120) == 0) {
    os_log(OS_LOG_DEFAULT, "[dusk::vision] headlook yaw=%.1f pitch=%.1f deg",
           (double)(yaw * 180.0f / kPi), (double)(pitch * 180.0f / kPi));
  }
}

}  // namespace dusk::vision::headlook

#endif  // visionOS
