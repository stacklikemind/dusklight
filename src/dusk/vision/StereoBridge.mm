// Dusk visionOS stereoscopic present: IOSurface <-> Dawn shared-texture import helper.
// See StereoBridge.h for the API contract. visionOS-only.
#include "dusk/vision/StereoBridge.h"

#if defined(__APPLE__) && defined(TARGET_OS_VISION) && TARGET_OS_VISION

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// visionOS simulator SDK ships <IOSurface/IOSurfaceRef.h> (create/property API), not the
// <IOSurface/IOSurface.h> umbrella; IOSurfaceRef.h is already pulled in via StereoBridge.h.

// Aurora's webgpu device/queue globals (extern/aurora/lib/webgpu/gpu.hpp). The visionOS Dusk target
// adds extern/aurora/lib to its include path so this resolves; it also declares the stereo capture
// hooks we use from the present loop.
#include "webgpu/gpu.hpp"

namespace dusk::vision {

IOSurfaceRef createBGRA8IOSurface(uint32_t width, uint32_t height) noexcept {
  if (width == 0 || height == 0) {
    return nullptr;
  }
  const size_t bytesPerElement = 4;  // BGRA8
  NSDictionary* props = @{
    (id)kIOSurfaceWidth : @(width),
    (id)kIOSurfaceHeight : @(height),
    (id)kIOSurfaceBytesPerElement : @(bytesPerElement),
    // 'BGRA' == kCVPixelFormatType_32BGRA. Matches wgpu::TextureFormat::BGRA8Unorm / MTLPixelFormatBGRA8Unorm.
    (id)kIOSurfacePixelFormat : @((unsigned)'BGRA'),
  };
  IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (surface == nullptr) {
    NSLog(@"[dusk::vision] IOSurfaceCreate failed for %ux%u", width, height);
  }
  return surface;  // +1 retained, caller owns.
}

SharedEyeTexture::~SharedEyeTexture() {
  if (m_metalTexture != nullptr) {
    CFRelease(m_metalTexture);
    m_metalTexture = nullptr;
  }
  if (m_lastEndAccessEvent != nullptr) {
    CFRelease(m_lastEndAccessEvent);
    m_lastEndAccessEvent = nullptr;
  }
  if (m_ioSurface != nullptr) {
    CFRelease(m_ioSurface);
    m_ioSurface = nullptr;
  }
}

bool SharedEyeTexture::init(IOSurfaceRef ioSurface, uint32_t width, uint32_t height,
                            wgpu::TextureFormat format) noexcept {
  if (ioSurface == nullptr || width == 0 || height == 0) {
    return false;
  }
  if (aurora::webgpu::g_device == nullptr) {
    NSLog(@"[dusk::vision] SharedEyeTexture::init: Aurora device not initialized");
    return false;
  }

  m_ioSurface = ioSurface;
  CFRetain(m_ioSurface);
  m_width = width;
  m_height = height;
  m_format = format;

  // Import the IOSurface as Dawn shared texture memory.
  wgpu::SharedTextureMemoryIOSurfaceDescriptor ioDesc;
  ioDesc.ioSurface = static_cast<void*>(m_ioSurface);  // field is void*; sType set by ctor.

  wgpu::SharedTextureMemoryDescriptor memDesc;
  memDesc.label = "Dusk Stereo Eye SharedTextureMemory";
  memDesc.nextInChain = &ioDesc;

  m_memory = aurora::webgpu::g_device.ImportSharedTextureMemory(&memDesc);
  if (m_memory == nullptr) {
    NSLog(@"[dusk::vision] ImportSharedTextureMemory failed");
    return false;
  }

  // Create the wgpu::Texture backed by that memory. Usage must allow Aurora's present blit
  // (RenderAttachment) and any copy paths (CopyDst).
  wgpu::TextureDescriptor texDesc;
  texDesc.label = "Dusk Stereo Eye Texture";
  texDesc.usage = wgpu::TextureUsage::RenderAttachment | wgpu::TextureUsage::CopyDst |
                  wgpu::TextureUsage::TextureBinding;
  texDesc.dimension = wgpu::TextureDimension::e2D;
  texDesc.size = {m_width, m_height, 1};
  texDesc.format = m_format;
  texDesc.mipLevelCount = 1;
  texDesc.sampleCount = 1;

  m_texture = m_memory.CreateTexture(&texDesc);
  if (m_texture == nullptr) {
    NSLog(@"[dusk::vision] SharedTextureMemory::CreateTexture failed");
    return false;
  }
  m_view = m_texture.CreateView();
  return m_view != nullptr;
}

bool SharedEyeTexture::beginAccess() noexcept {
  if (m_memory == nullptr || m_texture == nullptr) {
    return false;
  }
  // No import fences for the spike: Dawn assumes the texture is already in a usable state.
  // TODO(stereo): if the present side writes to the IOSurface, import its completion fence here.
  wgpu::SharedTextureMemoryBeginAccessDescriptor begin{};
  begin.concurrentRead = false;
  begin.initialized = true;
  begin.fenceCount = 0;
  begin.fences = nullptr;
  begin.signaledValueCount = 0;
  begin.signaledValues = nullptr;
  return m_memory.BeginAccess(m_texture, &begin) == wgpu::Status::Success;
}

bool SharedEyeTexture::endAccess() noexcept {
  if (m_memory == nullptr || m_texture == nullptr) {
    return false;
  }

  wgpu::SharedTextureMemoryEndAccessState end{};
  if (m_memory.EndAccess(m_texture, &end) != wgpu::Status::Success) {
    NSLog(@"[dusk::vision] SharedTextureMemory::EndAccess failed");
    return false;
  }

  // Export the first produced fence as an MTLSharedEvent so the present command buffer can wait on
  // it before reading the IOSurface. Dawn produces SharedFenceMTLSharedEvent fences when the
  // SharedFenceMTLSharedEvent device feature is enabled (it is; see gpu.cpp). Compute the new fence
  // into locals first, then publish under the lock so the present thread always reads a matched
  // (event, value) pair.
  id<MTLSharedEvent> newEvent = nil;
  uint64_t newValue = 0;
  if (end.fenceCount > 0 && end.fences != nullptr) {
    wgpu::SharedFenceMTLSharedEventExportInfo mtlExport;
    wgpu::SharedFenceExportInfo exportInfo{};
    exportInfo.nextInChain = &mtlExport;
    end.fences[0].ExportInfo(&exportInfo);
    if (mtlExport.sharedEvent != nullptr) {
      newEvent = (__bridge id<MTLSharedEvent>)mtlExport.sharedEvent;
      newValue = (end.signaledValues != nullptr) ? end.signaledValues[0] : 0;
    }
  }
  {
    std::lock_guard<std::mutex> lk(m_fenceMutex);
    if (m_lastEndAccessEvent != nullptr) {
      CFRelease(m_lastEndAccessEvent);
      m_lastEndAccessEvent = nullptr;
    }
    m_lastSignaledValue = newValue;
    if (newEvent != nil) {
      m_lastEndAccessEvent = (void*)CFBridgingRetain(newEvent);
    }
  }
  // TODO(stereo): if no MTLSharedEvent fence was produced, the present side must fall back to a
  // coarse device/queue poll (e.g. wait on a committed empty command buffer) before reading the
  // IOSurface. The fence-based path above is preferred and is what gpu.cpp's feature request enables.
  return true;
}

bool SharedEyeTexture::latestEndAccessFence(id<MTLSharedEvent>* outEvent,
                                            uint64_t* outValue) const noexcept {
  std::lock_guard<std::mutex> lk(m_fenceMutex);
  if (m_lastEndAccessEvent == nullptr) {
    if (outEvent != nullptr) {
      *outEvent = nil;
    }
    if (outValue != nullptr) {
      *outValue = 0;
    }
    return false;
  }
  // The __bridge cast hands ARC a +0 reference; assigning it to the caller's strong out-param retains
  // it, so the event survives even if a concurrent endAccess() CFReleases this object's reference.
  if (outEvent != nullptr) {
    *outEvent = (__bridge id<MTLSharedEvent>)m_lastEndAccessEvent;
  }
  if (outValue != nullptr) {
    *outValue = m_lastSignaledValue;
  }
  return true;
}

id<MTLTexture> SharedEyeTexture::metalTexture(id<MTLDevice> device) noexcept {
  if (device == nil || m_ioSurface == nullptr) {
    return nil;
  }
  if (m_metalTexture != nullptr) {
    return (__bridge id<MTLTexture>)m_metalTexture;
  }
  MTLTextureDescriptor* desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:m_width
                                                        height:m_height
                                                     mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  desc.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [device newTextureWithDescriptor:desc iosurface:m_ioSurface plane:0];
  if (tex == nil) {
    NSLog(@"[dusk::vision] newTextureWithDescriptor:iosurface: failed");
    return nil;
  }
  m_metalTexture = (void*)CFBridgingRetain(tex);
  return tex;
}

id<MTLSharedEvent> SharedEyeTexture::lastEndAccessSharedEvent() const noexcept {
  if (m_lastEndAccessEvent == nullptr) {
    return nil;
  }
  return (__bridge id<MTLSharedEvent>)m_lastEndAccessEvent;
}

}  // namespace dusk::vision

#endif  // visionOS
