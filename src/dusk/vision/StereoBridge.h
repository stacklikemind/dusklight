// Dusk visionOS stereoscopic present: IOSurface <-> Dawn shared-texture import helper.
//
// This wraps a caller-allocated IOSurface as a Dawn wgpu::SharedTextureMemory + wgpu::Texture so
// Aurora can blit the resolved present frame into it (see aurora::webgpu::set_stereo_capture_target),
// and exposes Metal-side handles (the IOSurface-backed MTLTexture + an MTLSharedEvent fence) so the
// CompositorServices present loop can read the frame and synchronize with the GPU.
//
// All visionOS-only. Guarded so it compiles to nothing elsewhere.
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#include <cstdint>

#include <IOSurface/IOSurfaceRef.h>
#include <webgpu/webgpu_cpp.h>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

namespace dusk::vision {

// Allocate a BGRA8 (unorm) IOSurface suitable for sharing between Dawn (Metal) and CompositorServices.
// Returns a +1 retained IOSurfaceRef (caller owns; release with CFRelease) or nullptr on failure.
IOSurfaceRef createBGRA8IOSurface(uint32_t width, uint32_t height) noexcept;

// Wraps an existing IOSurface as a Dawn shared texture that Aurora can render into. The IOSurface is
// retained for the lifetime of this object.
class SharedEyeTexture {
public:
  SharedEyeTexture() = default;
  ~SharedEyeTexture();

  SharedEyeTexture(const SharedEyeTexture&) = delete;
  SharedEyeTexture& operator=(const SharedEyeTexture&) = delete;

  // Imports `ioSurface` into Dawn. Returns false on failure (logs internally). `format` must match
  // the IOSurface pixel format (default BGRA8Unorm).
  bool init(IOSurfaceRef ioSurface, uint32_t width, uint32_t height,
            wgpu::TextureFormat format = wgpu::TextureFormat::BGRA8Unorm) noexcept;

  bool valid() const noexcept { return m_texture != nullptr; }
  uint32_t width() const noexcept { return m_width; }
  uint32_t height() const noexcept { return m_height; }

  // The Dawn texture view to hand to aurora::webgpu::set_stereo_capture_target().
  wgpu::TextureView view() const noexcept { return m_view; }
  const wgpu::Texture& texture() const noexcept { return m_texture; }
  IOSurfaceRef ioSurface() const noexcept { return m_ioSurface; }

  // Shared-texture access. Call beginAccess() before Aurora records the blit (each frame) and
  // endAccess() after. endAccess() reads the produced fence (MTLSharedEvent + value) so the present
  // side can wait on the GPU finishing the blit.
  bool beginAccess() noexcept;
  bool endAccess() noexcept;

#ifdef __OBJC__
  // Lazily create (and cache) an IOSurface-backed MTLTexture on `device` for the present-side blit.
  // The texture aliases the same IOSurface storage Dawn renders into.
  id<MTLTexture> metalTexture(id<MTLDevice> device) noexcept;

  // After endAccess(), the MTLSharedEvent the present command buffer should wait on, and the value
  // it will be signaled with. Returns nil/0 if no fence was produced (see TODO in the .mm).
  id<MTLSharedEvent> lastEndAccessSharedEvent() const noexcept;
#endif
  uint64_t lastEndAccessSignaledValue() const noexcept { return m_lastSignaledValue; }

private:
  IOSurfaceRef m_ioSurface = nullptr;
  uint32_t m_width = 0;
  uint32_t m_height = 0;
  wgpu::TextureFormat m_format = wgpu::TextureFormat::BGRA8Unorm;
  wgpu::SharedTextureMemory m_memory;
  wgpu::Texture m_texture;
  wgpu::TextureView m_view;

  // Metal handles are stored as void* so the header stays usable from non-ObjC translation units.
  void* m_metalTexture = nullptr;        // id<MTLTexture> (CFBridgingRetain'd)
  void* m_lastEndAccessEvent = nullptr;  // id<MTLSharedEvent> (CFBridgingRetain'd)
  uint64_t m_lastSignaledValue = 0;
};

}  // namespace dusk::vision

#endif  // visionOS
