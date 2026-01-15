#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <stdio.h>
#include <vector>
#include <string>
#include <string.h>
#include <filesystem>

#include "vj_sdk.hpp"

static void host_log_info(const char* msg)  { fprintf(stdout, "[host] %s\n", msg ? msg : ""); }
static void host_log_warn(const char* msg)  { fprintf(stderr, "[host][warn] %s\n", msg ? msg : ""); }
static void host_log_error(const char* msg) { fprintf(stderr, "[host][error] %s\n", msg ? msg : ""); }

struct PluginHandle {
  void* handle = nullptr;
  const vj_plugin_descriptor_t* desc = nullptr;
  vj_plugin_instance_t* inst = nullptr;
  vj_host_api_t host{};

  bool load(const char* path) {
    handle = dlopen(path, RTLD_NOW);
    if (!handle) { host_log_error(dlerror()); return false; }

    auto getter = (const vj_plugin_descriptor_t* (*)())dlsym(handle, "vj_plugin_get_descriptor");
    if (!getter) { host_log_error(dlerror()); unload(); return false; }

    desc = getter();
    if (!desc || !desc->create) { host_log_error("Invalid plugin descriptor"); unload(); return false; }

    host.api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR};
    host.log_info = host_log_info;
    host.log_warn = host_log_warn;
    host.log_error = host_log_error;
    host.malloc = malloc;
    host.free = free;

    inst = desc->create(&host);
    if (!inst) { host_log_error("create() returned null"); unload(); return false; }

    std::string label = desc->name ? desc->name : desc->plugin_id ? desc->plugin_id : "<plugin>";
    host_log_info(("Loaded " + label).c_str());
    return true;
  }

  void unload() {
    if (inst && desc && desc->destroy) desc->destroy(inst);
    inst = nullptr;
    desc = nullptr;
    if (handle) dlclose(handle);
    handle = nullptr;
  }

  ~PluginHandle() { unload(); }
};

static void set_example_params(PluginHandle& plugin) {
  if (!plugin.desc || !plugin.inst || !plugin.desc->set_param) return;
  auto set_float = [&](const char* id, float v) {
    vj_param_value_t val{}; val.type = VJ_PARAM_FLOAT; val.f = v;
    plugin.desc->set_param(plugin.inst, id, val);
  };
  auto set_int = [&](const char* id, int32_t v) {
    vj_param_value_t val{}; val.type = VJ_PARAM_INT; val.i = v;
    plugin.desc->set_param(plugin.inst, id, val);
  };
  auto set_bool = [&](const char* id, bool v) {
    vj_param_value_t val{}; val.type = VJ_PARAM_BOOL; val.b = v ? 1 : 0;
    plugin.desc->set_param(plugin.inst, id, val);
  };
  auto set_color = [&](const char* id, float r,float g,float b,float a=1.f) {
    vj_param_value_t val{}; val.type = VJ_PARAM_COLOR; val.color = vj_color_t{r,g,b,a};
    plugin.desc->set_param(plugin.inst, id, val);
  };

  const char* pid = plugin.desc->plugin_id ? plugin.desc->plugin_id : "";
  if (::strcmp(pid, "org.openvj.tranceglow") == 0) {
    set_float("amount", 0.9f);
    set_float("speed", 1.4f);
    set_float("zoom", 0.85f);
    set_bool("posterize", true);
    set_color("tint", 1.0f, 0.8f, 1.1f, 1.0f);
    host_log_info("Applied sample params for TranceGlow.");
  } else if (::strcmp(pid, "org.openvj.mandalagen") == 0) {
    set_int("symmetry", 12);
    set_float("spin", 2.0f);
    set_float("zoom", 1.2f);
    set_float("complexity", 0.7f);
    set_color("colorA", 0.1f, 0.9f, 1.0f, 1.0f);
    set_color("colorB", 1.0f, 0.4f, 0.8f, 1.0f);
    host_log_info("Applied sample params for MandalaGen.");
  }
}

static id<MTLTexture> make_texture(id<MTLDevice> device, uint32_t w, uint32_t h, bool for_input) {
  MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                   width:w
                                                                                  height:h
                                                                               mipmapped:NO];
  desc.storageMode = MTLStorageModeShared;
  desc.usage = for_input ? (MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)
                         : (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
  return [device newTextureWithDescriptor:desc];
}

static void fill_input(id<MTLTexture> tex) {
  if (!tex) return;
  const uint32_t w = (uint32_t)tex.width;
  const uint32_t h = (uint32_t)tex.height;
  std::vector<uint32_t> pixels(w * h, 0xff000000);
  for (uint32_t y = 0; y < h; ++y) {
    for (uint32_t x = 0; x < w; ++x) {
      uint8_t r = (uint8_t)((x * 255) / (w ? w - 1 : 1));
      uint8_t g = (uint8_t)((y * 255) / (h ? h - 1 : 1));
      uint8_t b = (uint8_t)(128);
      pixels[y * w + x] = (0xffu << 24) | (b << 16) | (g << 8) | r;
    }
  }
  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [tex replaceRegion:region mipmapLevel:0 withBytes:pixels.data() bytesPerRow:w * 4];
}

static uint64_t checksum_texture(id<MTLTexture> tex) {
  if (!tex) return 0;
  const uint32_t w = (uint32_t)tex.width;
  const uint32_t h = (uint32_t)tex.height;
  std::vector<uint8_t> bytes(w * h * 4);
  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [tex getBytes:bytes.data() bytesPerRow:w * 4 fromRegion:region mipmapLevel:0];
  uint64_t sum = 0;
  for (uint8_t v : bytes) sum += v;
  return sum;
}

static bool write_png(id<MTLTexture> tex, const char* path) {
  if (!tex || !path) return false;
  const uint32_t w = (uint32_t)tex.width;
  const uint32_t h = (uint32_t)tex.height;
  std::vector<uint8_t> bytes(w * h * 4);
  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [tex getBytes:bytes.data() bytesPerRow:w * 4 fromRegion:region mipmapLevel:0];

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, bytes.data(), bytes.size(), nullptr);
  CGBitmapInfo bi = kCGImageAlphaPremultipliedFirst;
  bi |= (CGBitmapInfo)kCGBitmapByteOrder32Little;
  CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, cs,
                                   bi, provider, nullptr, false, kCGRenderingIntentDefault);

  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path, strlen(path), false);
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
  if (!dest) {
    if (url) CFRelease(url);
    if (image) CGImageRelease(image);
    if (provider) CGDataProviderRelease(provider);
    if (cs) CGColorSpaceRelease(cs);
    return false;
  }
  CGImageDestinationAddImage(dest, image, nullptr);
  bool ok = CGImageDestinationFinalize(dest);

  CFRelease(dest);
  if (url) CFRelease(url);
  if (image) CGImageRelease(image);
  if (provider) CGDataProviderRelease(provider);
  if (cs) CGColorSpaceRelease(cs);
  return ok;
}

static bool run_one_frame(PluginHandle& plugin, id<MTLDevice> device, id<MTLCommandQueue> queue,
                          uint32_t w, uint32_t h, double time_seconds, const char* png_path) {
  if (!plugin.desc || !plugin.inst) return false;
  id<MTLTexture> inTex = nil;
  if (plugin.desc->kind != VJ_PLUGIN_GENERATOR) {
    inTex = make_texture(device, w, h, true);
    fill_input(inTex);
  }
  id<MTLTexture> outTex = make_texture(device, w, h, false);
  if (!outTex) { host_log_error("Failed to allocate textures"); return false; }

  id<MTLCommandBuffer> cb = [queue commandBuffer];
  if (!cb) { host_log_error("Failed to make command buffer"); return false; }

  vj_render_context_t ctx{};
  ctx.device = (__bridge void*)device;
  ctx.command_buffer = (__bridge void*)cb;
  ctx.output = (__bridge void*)outTex;
  ctx.width = w;
  ctx.height = h;
  ctx.time_seconds = time_seconds;
  ctx.delta_seconds = 1.0 / 60.0;
  ctx.frame_index = 1;

  if (plugin.desc->kind != VJ_PLUGIN_GENERATOR) {
    ctx.inputs[0] = (__bridge void*)inTex;
    ctx.input_count = 1;
  } else {
    ctx.input_count = 0;
  }

  plugin.desc->render(plugin.inst, &ctx);
  [cb commit];
  [cb waitUntilCompleted];

  uint64_t sum = checksum_texture(outTex);
  char buf[128];
  snprintf(buf, sizeof(buf), "Rendered %ux%u frame. Checksum: %llu",
           w, h, (unsigned long long)sum);
  host_log_info(buf);
  if (png_path && png_path[0]) {
    if (write_png(outTex, png_path)) {
      host_log_info(("Saved PNG: " + std::string(png_path)).c_str());
    } else {
      host_log_warn("Failed to write PNG.");
    }
  }
  return true;
}

int main(int argc, char** argv) {
  std::string plugin_path = "Build/Plugins/libTranceGlow.dylib";
  uint32_t width = 512, height = 512;
  uint32_t frames = 1;
  std::string out_dir;

  for (int i = 1; i < argc; ++i) {
    if (::strcmp(argv[i], "--plugin") == 0 && i + 1 < argc) {
      plugin_path = argv[++i];
    } else if (::strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
      frames = (uint32_t)atoi(argv[++i]);
    } else if (::strcmp(argv[i], "--size") == 0 && i + 2 < argc) {
      width = (uint32_t)atoi(argv[++i]);
      height = (uint32_t)atoi(argv[++i]);
    } else if (::strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
      out_dir = argv[++i];
    } else {
      plugin_path = argv[i];
    }
  }

  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) { host_log_error("No Metal device available."); return 1; }
  id<MTLCommandQueue> queue = [device newCommandQueue];
  if (!queue) { host_log_error("Failed to create command queue."); return 1; }

  PluginHandle plugin;
  if (!plugin.load(plugin_path.c_str())) return 1;

  set_example_params(plugin);

  if (!out_dir.empty()) {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec) {
      host_log_error(("Failed to create output dir: " + out_dir).c_str());
      return 1;
    }
  }

  for (uint32_t i = 0; i < frames; ++i) {
    double t = (double)i / 30.0; // simple timeline
    std::string png_path;
    if (!out_dir.empty()) {
      char fname[256];
      snprintf(fname, sizeof(fname), "frame_%04u.png", i);
      png_path = out_dir + "/" + fname;
    }
    if (!run_one_frame(plugin, device, queue, width, height, t, png_path.empty() ? nullptr : png_path.c_str()))
      return 1;
  }
  host_log_info("Done.");
  return 0;
}
