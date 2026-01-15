#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>
#include <chrono>
#include <thread>

#include "../SDK/include/vj_sdk.hpp"

static void host_log_info(const char* msg)  { fprintf(stdout, "[host] %s\n", msg ? msg : ""); }
static void host_log_warn(const char* msg)  { fprintf(stderr, "[host][warn] %s\n", msg ? msg : ""); }
static void host_log_error(const char* msg) { fprintf(stderr, "[host][error] %s\n", msg ? msg : ""); }

static std::string kind_to_string(vj_plugin_kind_t k) {
  switch (k) {
    case VJ_PLUGIN_GENERATOR:  return "generator";
    case VJ_PLUGIN_EFFECT:     return "effect";
    case VJ_PLUGIN_TRANSITION: return "transition";
    default: return "unknown";
  }
}

struct PluginHandle {
  void* handle = nullptr;
  const vj_plugin_descriptor_t* desc = nullptr;
  vj_plugin_instance_t* inst = nullptr;
  vj_host_api_t host{};

  bool load(const std::string& path) {
    handle = dlopen(path.c_str(), RTLD_NOW);
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
    host_log_info(("Loaded " + label + " (" + kind_to_string(desc->kind) + ")").c_str());
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

struct RunConfig {
  std::string plugin_path = "Build/Plugins/libTranceGlow.dylib";
  uint32_t width = 1280;
  uint32_t height = 720;
  uint32_t frames = 60;
  double fps = 30.0;
  std::string out_dir;
  std::string input_a;
  std::string input_b;
  std::string params_json;
  bool use_example_params = true;
  bool window = false;
};

static void print_help(const char* argv0) {
  fprintf(stdout,
"Usage: %s [--plugin PATH] [--frames N] [--size W H] [--fps N] [--out DIR]\n"
"           [--window]\n"
"           [--inputA PATH] [--inputB PATH] [--params FILE] [--no-example-params]\n"
"           [plugin_path]\n\n"
"Examples:\n"
"  %s --plugin Build/Plugins/libTranceGlow.dylib --frames 1 --out /tmp/out\n"
"  %s Build/Plugins/libMandalaGen.dylib --size 1024 1024 --fps 60\n"
"  %s --window --plugin Build/Plugins/libTranceGlow.dylib --frames 240 --fps 30\n"
"  %s --plugin my.dylib --params params.json --inputA input.png\n"
, argv0, argv0, argv0, argv0, argv0);
}

static bool parse_args(int argc, char** argv, RunConfig& cfg) {
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") { print_help(argv[0]); return false; }
    if (arg == "--plugin" && i + 1 < argc) {
      cfg.plugin_path = argv[++i];
    } else if (arg == "--frames" && i + 1 < argc) {
      cfg.frames = (uint32_t)std::max(1, atoi(argv[++i]));
    } else if (arg == "--size" && i + 2 < argc) {
      cfg.width = (uint32_t)std::max(1, atoi(argv[++i]));
      cfg.height = (uint32_t)std::max(1, atoi(argv[++i]));
    } else if (arg == "--fps" && i + 1 < argc) {
      cfg.fps = std::max(1.0, atof(argv[++i]));
    } else if (arg == "--out" && i + 1 < argc) {
      cfg.out_dir = argv[++i];
    } else if (arg == "--inputA" && i + 1 < argc) {
      cfg.input_a = argv[++i];
    } else if (arg == "--inputB" && i + 1 < argc) {
      cfg.input_b = argv[++i];
    } else if (arg == "--params" && i + 1 < argc) {
      cfg.params_json = argv[++i];
    } else if (arg == "--no-example-params") {
      cfg.use_example_params = false;
    } else if (arg == "--window") {
      cfg.window = true;
    } else if (!arg.empty() && arg[0] != '-') {
      cfg.plugin_path = arg;
    } else {
      host_log_warn(("Unknown argument: " + arg).c_str());
    }
  }
  return true;
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

static void fill_gradient(id<MTLTexture> tex, float phase = 0.0f) {
  if (!tex) return;
  const uint32_t w = (uint32_t)tex.width;
  const uint32_t h = (uint32_t)tex.height;
  std::vector<uint32_t> pixels(w * h, 0xff000000);
  for (uint32_t y = 0; y < h; ++y) {
    for (uint32_t x = 0; x < w; ++x) {
      float fx = (float)x / std::max(1u, w - 1);
      float fy = (float)y / std::max(1u, h - 1);
      uint8_t r = (uint8_t)std::clamp<int>(int((fx + phase) * 255.0f) % 255, 0, 255);
      uint8_t g = (uint8_t)std::clamp<int>(int((fy + 0.25f * phase) * 255.0f) % 255, 0, 255);
      uint8_t b = (uint8_t)(128);
      pixels[y * w + x] = (0xffu << 24) | (b << 16) | (g << 8) | r;
    }
  }
  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [tex replaceRegion:region mipmapLevel:0 withBytes:pixels.data() bytesPerRow:w * 4];
}

static id<MTLTexture> load_texture_from_file(id<MTLDevice> device, const std::string& path,
                                             uint32_t target_w, uint32_t target_h) {
  NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  if (!src) { host_log_warn(("Could not open image: " + path).c_str()); return nil; }
  CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
  if (!img) { host_log_warn(("Could not decode image: " + path).c_str()); CFRelease(src); return nil; }

  id<MTLTexture> tex = make_texture(device, target_w, target_h, true);
  if (!tex) { host_log_warn("Failed to allocate texture for input image."); CFRelease(img); CFRelease(src); return nil; }

  std::vector<uint8_t> bytes(target_w * target_h * 4, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGBitmapInfo bi = kCGImageAlphaPremultipliedFirst;
  bi |= (CGBitmapInfo)kCGBitmapByteOrder32Little;
  CGContextRef ctx = CGBitmapContextCreate(bytes.data(), target_w, target_h, 8, target_w * 4,
                                           cs,
                                           bi);
  if (cs) CGColorSpaceRelease(cs);
  if (ctx) {
    CGContextClearRect(ctx, CGRectMake(0, 0, target_w, target_h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, target_w, target_h), img);
    CGContextRelease(ctx);
    MTLRegion region = MTLRegionMake2D(0, 0, target_w, target_h);
    [tex replaceRegion:region mipmapLevel:0 withBytes:bytes.data() bytesPerRow:target_w * 4];
  } else {
    host_log_warn("Failed to create CGContext for input image.");
  }

  CFRelease(img);
  CFRelease(src);
  return tex;
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

static bool write_png(id<MTLTexture> tex, const std::string& path) {
  if (!tex || path.empty()) return false;
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

  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path.c_str(), path.size(), false);
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

static void describe_plugin(const PluginHandle& plugin) {
  if (!plugin.desc || !plugin.inst) return;
  std::ostringstream oss;
  oss << "Plugin: " << (plugin.desc->name ? plugin.desc->name : "<unnamed>");
  if (plugin.desc->plugin_id) oss << " (" << plugin.desc->plugin_id << ")";
  oss << "\n  Kind: " << kind_to_string(plugin.desc->kind);
  if (plugin.desc->vendor) oss << "\n  Vendor: " << plugin.desc->vendor;
  if (plugin.desc->description) oss << "\n  Description: " << plugin.desc->description;
  host_log_info(oss.str().c_str());

  if (!plugin.desc->get_param_count || !plugin.desc->get_param_desc) return;
  uint32_t count = plugin.desc->get_param_count(plugin.inst);
  if (count == 0) {
    host_log_info("  Params: none");
    return;
  }
  host_log_info("  Params:");
  for (uint32_t i = 0; i < count; ++i) {
    const vj_param_desc_t* p = plugin.desc->get_param_desc(plugin.inst, i);
    if (!p || !p->id) continue;
    std::string line = "    - ";
    line += p->id;
    if (p->label) line += " (" + std::string(p->label) + ")";
    line += " : ";
    switch (p->type) {
      case VJ_PARAM_FLOAT: line += "float"; break;
      case VJ_PARAM_INT: line += "int"; break;
      case VJ_PARAM_BOOL: line += "bool"; break;
      case VJ_PARAM_ENUM: line += "enum"; break;
      case VJ_PARAM_COLOR: line += "color"; break;
      default: line += "unknown"; break;
    }
    host_log_info(line.c_str());
  }
}

static const vj_param_desc_t* find_param(const PluginHandle& plugin, std::string_view id) {
  if (!plugin.desc || !plugin.inst || !plugin.desc->get_param_count || !plugin.desc->get_param_desc) return nullptr;
  uint32_t count = plugin.desc->get_param_count(plugin.inst);
  for (uint32_t i = 0; i < count; ++i) {
    const vj_param_desc_t* p = plugin.desc->get_param_desc(plugin.inst, i);
    if (p && p->id && id == p->id) return p;
  }
  return nullptr;
}

static bool case_insensitive_eq(std::string_view a, std::string_view b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i])) return false;
  }
  return true;
}

static bool json_to_value(const vj_param_desc_t& desc, id obj, vj_param_value_t& out, std::string& error) {
  auto clampf = [](float v, float mn, float mx) {
    if (mn < mx) return std::clamp(v, mn, mx);
    return v;
  };
  auto clampi = [](int32_t v, int32_t mn, int32_t mx) {
    if (mn < mx) return std::clamp(v, mn, mx);
    return v;
  };

  switch (desc.type) {
    case VJ_PARAM_FLOAT: {
      if (![obj isKindOfClass:[NSNumber class]]) { error = "expected number"; return false; }
      float v = (float)[(NSNumber*)obj doubleValue];
      out.type = VJ_PARAM_FLOAT;
      out.f = clampf(v, desc.f_min, desc.f_max);
      return true;
    }
    case VJ_PARAM_INT: {
      if (![obj isKindOfClass:[NSNumber class]]) { error = "expected number"; return false; }
      int32_t v = (int32_t)[(NSNumber*)obj longLongValue];
      out.type = VJ_PARAM_INT;
      out.i = clampi(v, desc.i_min, desc.i_max);
      return true;
    }
    case VJ_PARAM_BOOL: {
      if (![obj isKindOfClass:[NSNumber class]]) { error = "expected number/bool"; return false; }
      out.type = VJ_PARAM_BOOL;
      out.b = ([(NSNumber*)obj intValue] != 0) ? 1 : 0;
      return true;
    }
    case VJ_PARAM_ENUM: {
      out.type = VJ_PARAM_ENUM;
      if ([obj isKindOfClass:[NSNumber class]]) {
        int32_t idx = (int32_t)[(NSNumber*)obj intValue];
        if (desc.enum_count > 0) {
          idx = clampi(idx, 0, (int32_t)desc.enum_count - 1);
        }
        out.i = idx;
        return true;
      }
      if ([obj isKindOfClass:[NSString class]]) {
        NSString* s = (NSString*)obj;
        std::string label = [s UTF8String];
        for (uint32_t i = 0; i < desc.enum_count; ++i) {
          const char* l = desc.enum_labels ? desc.enum_labels[i] : nullptr;
          if (l && case_insensitive_eq(label, l)) {
            out.i = (int32_t)i;
            return true;
          }
        }
        error = "enum label not found";
        return false;
      }
      error = "expected number or string";
      return false;
    }
    case VJ_PARAM_COLOR: {
      if (![obj isKindOfClass:[NSArray class]]) { error = "expected array of 3 or 4 numbers"; return false; }
      NSArray* arr = (NSArray*)obj;
      if ([arr count] < 3) { error = "expected array of 3 or 4 numbers"; return false; }
      float comps[4] = {1.f, 1.f, 1.f, 1.f};
      for (NSUInteger i = 0; i < std::min<NSUInteger>([arr count], 4); ++i) {
        id item = arr[i];
        if (![item isKindOfClass:[NSNumber class]]) { error = "color component not a number"; return false; }
        comps[i] = (float)[(NSNumber*)item doubleValue];
      }
      out.type = VJ_PARAM_COLOR;
      out.color = vj_color_t{
        clampf(comps[0], 0.f, 1.f),
        clampf(comps[1], 0.f, 1.f),
        clampf(comps[2], 0.f, 1.f),
        clampf(comps[3], 0.f, 1.f)
      };
      return true;
    }
    default:
      error = "unsupported param type";
      return false;
  }
}

static void apply_params_from_json(PluginHandle& plugin, const std::string& path) {
  if (path.empty()) return;
  NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
  if (!data) { host_log_warn(("Could not read params file: " + path).c_str()); return; }
  NSError* err = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err || !json || ![json isKindOfClass:[NSDictionary class]]) {
    host_log_warn(("Invalid JSON in params file: " + path).c_str());
    return;
  }

  NSDictionary* dict = (NSDictionary*)json;
  [dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL* stop) {
    if (![key isKindOfClass:[NSString class]]) return;
    std::string idStr = [(NSString*)key UTF8String];
    const vj_param_desc_t* desc = find_param(plugin, idStr);
    if (!desc) {
      host_log_warn(("Param not found on plugin: " + idStr).c_str());
      return;
    }
    vj_param_value_t val{};
    std::string error;
    if (!json_to_value(*desc, obj, val, error)) {
      host_log_warn(("Failed to parse value for " + idStr + ": " + error).c_str());
      return;
    }
    if (plugin.desc && plugin.desc->set_param) {
      plugin.desc->set_param(plugin.inst, desc->id, val);
      host_log_info(("Set param " + idStr).c_str());
    }
  }];
}

static void apply_example_params_if_known(PluginHandle& plugin) {
  if (!plugin.desc || !plugin.inst || !plugin.desc->set_param || !plugin.desc->plugin_id) return;
  const char* pid = plugin.desc->plugin_id;
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

struct RenderInputs {
  id<MTLTexture> inputs[2]{};
  uint32_t count = 0;
};

struct DisplaySurface {
  NSWindow* window = nil;
  MTKView* view = nil;
  bool valid() const { return window && view; }
};

static DisplaySurface create_display(uint32_t w, uint32_t h, id<MTLDevice> device) {
  DisplaySurface d{};
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSRect rect = NSMakeRect(0, 0, w, h);
  NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
  d.window = [[NSWindow alloc] initWithContentRect:rect styleMask:style backing:NSBackingStoreBuffered defer:NO];
  d.view = [[MTKView alloc] initWithFrame:rect device:device];
  if (d.view) {
    d.view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    d.view.framebufferOnly = NO;
    d.view.drawableSize = CGSizeMake(w, h);
    d.view.enableSetNeedsDisplay = NO;
    d.view.paused = YES;
    d.view.preferredFramesPerSecond = 0;
  }
  if (d.window && d.view) {
    [d.window setContentView:d.view];
    [d.window makeKeyAndOrderFront:nil];
    [d.window center];
    [NSApp activateIgnoringOtherApps:YES];
  }
  return d;
}

static void pump_events() {
  NSEvent* event = nil;
  while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                     untilDate:[NSDate dateWithTimeIntervalSinceNow:0]
                                        inMode:NSDefaultRunLoopMode
                                       dequeue:YES])) {
    [NSApp sendEvent:event];
  }
}

static RenderInputs prepare_inputs(id<MTLDevice> device, const RunConfig& cfg, vj_plugin_kind_t kind) {
  RenderInputs ri{};
  if (kind == VJ_PLUGIN_GENERATOR) return ri;

  auto load_or_gradient = [&](const std::string& path, float phase) -> id<MTLTexture> {
    id<MTLTexture> tex = nil;
    if (!path.empty() && std::filesystem::exists(path)) {
      tex = load_texture_from_file(device, path, cfg.width, cfg.height);
      if (!tex) host_log_warn(("Falling back to gradient for input: " + path).c_str());
    }
    if (!tex) tex = make_texture(device, cfg.width, cfg.height, true);
    fill_gradient(tex, phase);
    return tex;
  };

  ri.inputs[0] = load_or_gradient(cfg.input_a, 0.0f);
  ri.count = 1;
  if (kind == VJ_PLUGIN_TRANSITION) {
    ri.inputs[1] = load_or_gradient(cfg.input_b, 0.35f);
    ri.count = 2;
  }
  return ri;
}

static bool run_frame(PluginHandle& plugin, id<MTLDevice> device, id<MTLCommandQueue> queue,
                      const RunConfig& cfg, const RenderInputs& ri,
                      uint64_t frame_index, const std::string& png_path,
                      const DisplaySurface* display) {
  if (!plugin.desc || !plugin.inst || !plugin.desc->render) return false;

  bool use_window = display && display->view && display->window;
  id<CAMetalDrawable> drawable = nil;
  id<MTLTexture> outTex = nil;
  id<MTLTexture> captureTex = nil;

  if (use_window) {
    drawable = [display->view currentDrawable];
    if (!drawable) { host_log_warn("No drawable available for window."); return false; }
    outTex = drawable.texture;
    if (!outTex) { host_log_warn("Drawable has no texture."); return false; }
    if (!png_path.empty()) captureTex = make_texture(device, cfg.width, cfg.height, false);
  } else {
    outTex = make_texture(device, cfg.width, cfg.height, false);
    if (!outTex) { host_log_error("Failed to allocate output texture"); return false; }
  }

  id<MTLCommandBuffer> cb = [queue commandBuffer];
  if (!cb) { host_log_error("Failed to create command buffer"); return false; }

  vj_render_context_t ctx{};
  ctx.device = (__bridge void*)device;
  ctx.command_buffer = (__bridge void*)cb;
  ctx.output = (__bridge void*)outTex;
  ctx.width = cfg.width;
  ctx.height = cfg.height;
  ctx.time_seconds = (double)frame_index / std::max(1.0, cfg.fps);
  ctx.delta_seconds = 1.0 / std::max(1.0, cfg.fps);
  ctx.frame_index = frame_index;

  if (ri.count > 0) {
    ctx.input_count = std::min<uint32_t>(ri.count, 2);
    ctx.inputs[0] = (__bridge void*)ri.inputs[0];
    if (ri.count > 1) ctx.inputs[1] = (__bridge void*)ri.inputs[1];
  }

  plugin.desc->render(plugin.inst, &ctx);

  if (captureTex) {
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (blit) {
      MTLOrigin origin = {0, 0, 0};
      MTLSize size = {cfg.width, cfg.height, 1};
      [blit copyFromTexture:outTex
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:origin
                 sourceSize:size
                  toTexture:captureTex
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:origin];
      [blit endEncoding];
    }
  }

  if (use_window && drawable) {
    [cb presentDrawable:drawable];
  }

  [cb commit];
  [cb waitUntilCompleted];

  if (use_window && png_path.empty()) {
    return true; // live only, skip checksum
  }

  uint64_t sum = checksum_texture(captureTex ? captureTex : outTex);
  char buf[128];
  snprintf(buf, sizeof(buf), "Frame %llu checksum: %llu",
           (unsigned long long)frame_index,
           (unsigned long long)sum);
  host_log_info(buf);

  if (!png_path.empty()) {
    id<MTLTexture> readTex = captureTex ? captureTex : outTex;
    if (write_png(readTex, png_path)) {
      host_log_info(("Saved " + png_path).c_str());
    } else {
      host_log_warn(("Failed to write PNG: " + png_path).c_str());
    }
  }
  return true;
}

int main(int argc, char** argv) {
  int ret = 0;
  @autoreleasepool {
    RunConfig cfg;
    if (!parse_args(argc, argv, cfg)) { ret = 0; goto done; }

    if (!std::filesystem::exists(cfg.plugin_path)) {
      host_log_error(("Plugin not found: " + cfg.plugin_path).c_str());
      ret = 1; goto done;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { host_log_error("No Metal device available."); ret = 1; goto done; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) { host_log_error("Failed to create command queue."); ret = 1; goto done; }

    PluginHandle plugin;
    if (!plugin.load(cfg.plugin_path)) { ret = 1; goto done; }

    describe_plugin(plugin);

    if (!cfg.params_json.empty()) {
      apply_params_from_json(plugin, cfg.params_json);
    } else if (cfg.use_example_params) {
      apply_example_params_if_known(plugin);
    }

    RenderInputs ri = prepare_inputs(device, cfg, plugin.desc ? plugin.desc->kind : VJ_PLUGIN_EFFECT);

    DisplaySurface display;
    if (cfg.window) {
      display = create_display(cfg.width, cfg.height, device);
      if (!display.valid()) {
        host_log_error("Failed to create display window.");
        ret = 1; goto done;
      }
    }

    if (!cfg.out_dir.empty()) {
      std::error_code ec;
      std::filesystem::create_directories(cfg.out_dir, ec);
      if (ec) {
        host_log_error(("Failed to create output dir: " + cfg.out_dir).c_str());
        ret = 1; goto done;
      }
    }

    for (uint32_t i = 0; i < cfg.frames; ++i) {
      @autoreleasepool {
        pump_events();
        if (cfg.window && (!display.window || ![display.window isVisible])) {
          host_log_info("Window closed, stopping.");
          break;
        }

        std::string png_path;
        if (!cfg.out_dir.empty()) {
          char fname[256];
          snprintf(fname, sizeof(fname), "frame_%04u.png", i);
          png_path = cfg.out_dir + "/" + fname;
        }
        if (!run_frame(plugin, device, queue, cfg, ri, i, png_path, cfg.window ? &display : nullptr)) { ret = 1; goto done; }

        if (cfg.window) {
          using namespace std::chrono;
          double frame_seconds = 1.0 / std::max(1.0, cfg.fps);
          std::this_thread::sleep_for(duration<double>(frame_seconds));
        }
      }
    }

    host_log_info("Done.");
  }
done:
  return ret;
}
