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
// Full-matrix head-look: apply the head's relative VIEW change (inverse of its motion since recenter)
// directly to the game view matrix. Correct at ALL head orientations -- unlike the old yaw/pitch
// decomposition, which reversed pitch/roll past ~90deg. ARKit head-view space matches TP's view space
// (right-handed, X-right/Y-up/Z-back, looking -Z, per mDoMtx_lookAt), so it maps with no basis change.
// kBasis{X,Y,Z} are an on-device escape hatch if an axis turns out inverted; keep an EVEN count of -1
// (odd = a mirror/reflection). kHeadTranslateScale = game units per real meter (TP's world scale is
// unknown -> tune; 0 disables translation = pure 3DoF). It is THE comfort knob.
constexpr float kBasisX = 1.0f;
constexpr float kBasisY = 1.0f;
constexpr float kBasisZ = 1.0f;
constexpr float kHeadTranslateScale = 50.0f;
// TEST: the gameplay loop rewrites the camera every frame, fighting the additive head-look. While the
// head is ~centered we track the game's live camera (it follows Link normally); once the head moves
// past these thresholds we FREEZE that base and let head-look drive from it, so the game can't cancel
// head movement. Set kFreezeBaseCamera false to restore pure-additive behavior.
constexpr bool kFreezeBaseCamera = true;
constexpr float kCenterRotRad = 0.05f;   // ~3 deg from forward counts as "centered"
constexpr float kCenterTransM = 0.03f;   // 3 cm
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
  // Head-look runs ONLY in the face-locked mode. In the world-locked screen (the default) the compositor
  // already handles head motion by reprojecting the fixed screen; driving the game camera from the head
  // there pans the on-screen CONTENT against the FIXED screen frame -> "fighting" at the edges (and only
  // during gameplay, since head-look is suppressed in cutscenes). Gating on the mode also overrides a
  // persisted game.visionHeadLook=true from before the default flipped off.
  if (dusk::getSettings().game.visionWorldLockedScreen.getValue() ||
      !dusk::getSettings().game.visionHeadLook.getValue()) {
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

  // Head pose relative to the recenter reference, in the reference frame.
  const simd_float4x4 rel = simd_mul(simd_inverse(ref), cur);
  // ARKit cameras look down -Z; rel.columns[2] is the head's +Z basis in the reference frame.
  const simd_float3 fwd = -simd_make_float3(rel.columns[2].x, rel.columns[2].y, rel.columns[2].z);
  const simd_float3 t = simd_make_float3(rel.columns[3].x, rel.columns[3].y, rel.columns[3].z);

  const float rotMag = std::acos(std::fmax(-1.0f, std::fmin(1.0f, -fwd.z)));  // head angle from forward

  // Stop the gameplay loop from fighting head movement: while the head is ~centered, track the game's
  // live camera (so it follows Link normally); once the head moves off-center, FREEZE that base so the
  // game's per-frame camera rewrite can't cancel the head offset. Engine-thread only (no lock).
  static Mtx s_frozenView;
  static bool s_haveFrozen = false;
  if (kFreezeBaseCamera) {
    const bool centered = (rotMag < kCenterRotRad) && (simd_length(t) < kCenterTransM);
    if (centered || !s_haveFrozen) {
      cMtx_copy(viewMtx, s_frozenView);  // track the game camera while centered
      s_haveFrozen = true;
    } else {
      cMtx_copy(s_frozenView, viewMtx);  // hold the base while the head is moved -> game can't fight
    }
  }

  // Full-matrix head-look: compose the head's relative VIEW change onto the (frozen) view matrix in view
  // space. inverse(rel) IS that view change (rel = head motion since recenter); the basis conjugation
  // (identity by default) is an on-device escape hatch for axis-sign fixes. Convert the simd (column-
  // major) result to a GameCube Mtx (row-major 3x4) and scale ONLY the translation column (meters ->
  // game units). Using the full matrix -- not a yaw/pitch decomposition -- keeps it correct at ANY head
  // orientation, with no 180-degree reversal.
  simd_float4x4 basis = matrix_identity_float4x4;
  basis.columns[0].x = kBasisX;
  basis.columns[1].y = kBasisY;
  basis.columns[2].z = kBasisZ;
  const simd_float4x4 H = simd_inverse(simd_mul(simd_mul(basis, rel), basis));
  Mtx headOffset;
  for (int r = 0; r < 3; ++r) {
    headOffset[r][0] = H.columns[0][r];
    headOffset[r][1] = H.columns[1][r];
    headOffset[r][2] = H.columns[2][r];
    headOffset[r][3] = H.columns[3][r] * kHeadTranslateScale;  // meters -> game units
  }
  Mtx out;
  cMtx_concat(headOffset, viewMtx, out);
  cMtx_copy(out, viewMtx);

  static unsigned long s_diag = 0;
  if ((s_diag++ % 120) == 0) {
    os_log(OS_LOG_DEFAULT, "[dusk::vision] headlook rot=%.1fdeg t=(%.1f,%.1f,%.1f)cm",
           (double)(rotMag * 180.0f / kPi), (double)(t.x * 100.0f), (double)(t.y * 100.0f),
           (double)(t.z * 100.0f));
  }
}

}  // namespace dusk::vision::headlook

#endif  // visionOS
