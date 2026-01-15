#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <vector>
#include <string>
#include <filesystem>
#include <chrono>
#include <thread>
#include <algorithm>
#include <unordered_map>
#include <memory>
#include <functional>

#include "../SDK/include/vj_sdk.hpp"

static void host_log_info(const char* msg)  { fprintf(stdout, "[host] %s\n", msg ? msg : ""); }
static void host_log_warn(const char* msg)  { fprintf(stderr, "[host][warn] %s\n", msg ? msg : ""); }
static void host_log_error(const char* msg) { fprintf(stderr, "[host][error] %s\n", msg ? msg : ""); }

struct PluginLibrary {
  void* handle = nullptr;
  const vj_plugin_descriptor_t* desc = nullptr;
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
    return true;
  }

  vj_plugin_instance_t* create_instance() {
    if (!desc || !desc->create) return nullptr;
    return desc->create(&host);
  }

  void unload() {
    desc = nullptr;
    if (handle) dlclose(handle);
    handle = nullptr;
  }
  ~PluginLibrary() { unload(); }
};

struct PluginInstance {
  PluginLibrary* lib = nullptr;
  vj_plugin_instance_t* inst = nullptr;
  void destroy() {
    if (inst && lib && lib->desc && lib->desc->destroy) lib->desc->destroy(inst);
    inst = nullptr;
  }
};

struct LibraryCache {
  std::unordered_map<std::string, std::unique_ptr<PluginLibrary>> libs;
  PluginLibrary* get(const std::string& path) {
    auto it = libs.find(path);
    if (it != libs.end()) return it->second.get();
    auto lib = std::make_unique<PluginLibrary>();
    if (!lib->load(path)) return nullptr;
    auto* ptr = lib.get();
    libs[path] = std::move(lib);
    return ptr;
  }
};

struct ImageSequence {
  std::vector<std::string> frames;
  double fps = 24.0;
  bool valid() const { return !frames.empty(); }

  std::string frame_for_time(double t) const {
    if (frames.empty()) return {};
    size_t idx = (size_t)fmod(t * fps, (double)frames.size());
    return frames[idx];
  }
};

struct ConfigData {
  std::vector<std::string> tileSeqs;
  std::vector<std::string> textPresets;
};

static ImageSequence load_sequence(const std::string& dir) {
  ImageSequence seq;
  if (dir.empty() || !std::filesystem::is_directory(dir)) return seq;
  for (auto& entry : std::filesystem::directory_iterator(dir)) {
    if (!entry.is_regular_file()) continue;
    auto path = entry.path().string();
    auto name = entry.path().filename().string();
    if (name.rfind("frame_", 0) == 0) seq.frames.push_back(path);
  }
  std::sort(seq.frames.begin(), seq.frames.end());
  if (!seq.frames.empty()) seq.fps = 24.0;
  return seq;
}

static std::string env_or_config_seq(size_t tileIndex, const std::vector<std::string>& cfg, const std::string& fallback) {
  char buf[64];
  snprintf(buf, sizeof(buf), "VJ_TILE%zu_SEQ", tileIndex + 1);
  const char* env = getenv(buf);
  if (env && env[0]) return std::string(env);
  if (tileIndex < cfg.size() && !cfg[tileIndex].empty()) return cfg[tileIndex];
  return fallback;
}

static ConfigData load_config(const std::filesystem::path& path) {
  ConfigData cfg;
  cfg.tileSeqs.resize(9);
  for (size_t i = 0; i < cfg.tileSeqs.size(); ++i) {
    cfg.tileSeqs[i] = "Media/Tile" + std::to_string(i + 1);
  }
  if (!std::filesystem::exists(path)) return cfg;
  NSString* nsPath = [NSString stringWithUTF8String:path.string().c_str()];
  NSData* data = [NSData dataWithContentsOfFile:nsPath];
  if (!data) return cfg;
  NSError* err = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err || !json || ![json isKindOfClass:[NSDictionary class]]) return cfg;
  NSDictionary* dict = (NSDictionary*)json;
  NSArray* vids = dict[@"videos"];
  if ([vids isKindOfClass:[NSArray class]]) {
    for (id item in vids) {
      if (![item isKindOfClass:[NSDictionary class]]) continue;
      NSNumber* tileNum = [(NSDictionary*)item objectForKey:@"tile"];
      NSString* pathStr = [(NSDictionary*)item objectForKey:@"path"];
      if (![tileNum isKindOfClass:[NSNumber class]] || ![pathStr isKindOfClass:[NSString class]]) continue;
      int t = [tileNum intValue];
      if (t < 1 || t > 9) continue;
      cfg.tileSeqs[(size_t)(t - 1)] = std::string([pathStr UTF8String]);
    }
  }
  NSArray* texts = dict[@"text_presets"];
  if ([texts isKindOfClass:[NSArray class]]) {
    for (id s in texts) {
      if (![s isKindOfClass:[NSString class]]) continue;
      cfg.textPresets.push_back(std::string([(NSString*)s UTF8String]));
    }
  }
  return cfg;
}

struct Tile; // forward decl

static std::vector<uint8_t> load_image_scaled(const std::string& path, uint32_t w, uint32_t h) {
  std::vector<uint8_t> out;
  if (path.empty() || w == 0 || h == 0) return out;
  NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  if (!src) return out;
  CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
  if (!img) { CFRelease(src); return out; }

  out.resize(w * h * 4);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
  bi |= (CGBitmapInfo)kCGBitmapByteOrder32Little;
  CGContextRef ctx = CGBitmapContextCreate(out.data(), w, h, 8, w*4, cs, bi);
  if (ctx) {
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0,0,w,h), img);
    CGContextRelease(ctx);
  } else {
    out.clear();
  }
  if (cs) CGColorSpaceRelease(cs);
  if (img) CGImageRelease(img);
  if (src) CFRelease(src);
  return out;
}

static id<MTLTexture> make_texture(id<MTLDevice> device, uint32_t w, uint32_t h) {
  MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                   width:w
                                                                                  height:h
                                                                               mipmapped:NO];
  desc.storageMode = MTLStorageModeShared;
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  return [device newTextureWithDescriptor:desc];
}

static std::vector<uint8_t> read_texture_bytes(id<MTLTexture> tex) {
  std::vector<uint8_t> empty;
  if (!tex) return empty;
  uint32_t w = (uint32_t)tex.width;
  uint32_t h = (uint32_t)tex.height;
  std::vector<uint8_t> bytes(w * h * 4);
  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [tex getBytes:bytes.data() bytesPerRow:w*4 fromRegion:region mipmapLevel:0];
  return bytes;
}

static NSImage* bytes_to_image(const std::vector<uint8_t>& bytes, uint32_t w, uint32_t h) {
  if (bytes.empty() || w == 0 || h == 0) return nil;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, bytes.data(), bytes.size(), nullptr);
  CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
  bi |= (CGBitmapInfo)kCGBitmapByteOrder32Little;
  CGImageRef image = CGImageCreate(w, h, 8, 32, w*4, cs, bi, provider, nullptr, false, kCGRenderingIntentDefault);
  NSImage* nsimg = nil;
  if (image) {
    nsimg = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(w, h)];
    CGImageRelease(image);
  }
  if (provider) CGDataProviderRelease(provider);
  if (cs) CGColorSpaceRelease(cs);
  return nsimg;
}

static id<MTLTexture> render_once(PluginInstance& pi, id<MTLDevice> dev, id<MTLCommandQueue> queue,
                                  uint32_t w, uint32_t h, double t,
                                  id<MTLTexture> input0 = nil, id<MTLTexture> input1 = nil) {
  if (!pi.lib || !pi.inst || !pi.lib->desc || !pi.lib->desc->render) return nil;
  id<MTLTexture> outTex = make_texture(dev, w, h);
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  vj_render_context_t ctx{};
  ctx.device = (__bridge void*)dev;
  ctx.command_buffer = (__bridge void*)cb;
  ctx.output = (__bridge void*)outTex;
  ctx.width = w;
  ctx.height = h;
  ctx.time_seconds = t;
  ctx.delta_seconds = 1.0 / 30.0;
  ctx.frame_index = (uint64_t)(t * 30.0);
  if (input0) { ctx.inputs[0] = (__bridge void*)input0; ctx.input_count = 1; }
  if (input1) { ctx.inputs[1] = (__bridge void*)input1; ctx.input_count = 2; }
  pi.lib->desc->render(pi.inst, &ctx);
  [cb commit];
  [cb waitUntilCompleted];
  return outTex;
}

static std::vector<uint8_t> mix_four(const std::vector<uint8_t>& a,
                                     const std::vector<uint8_t>& b,
                                     const std::vector<uint8_t>& c,
                                     const std::vector<uint8_t>& d,
                                     uint32_t w, uint32_t h,
                                     float u, float v) {
  std::vector<uint8_t> out(w * h * 4, 0);
  if (a.empty() || b.empty() || c.empty() || d.empty()) return out;
  float w00 = (1.f - u) * (1.f - v);
  float w10 = u * (1.f - v);
  float w01 = (1.f - u) * v;
  float w11 = u * v;
  for (uint32_t i = 0; i < w*h; ++i) {
    size_t idx = i*4;
    for (int cidx=0;cidx<4;++cidx) {
      float va = a[idx+cidx];
      float vb = b[idx+cidx];
      float vc = c[idx+cidx];
      float vd = d[idx+cidx];
      float res = va*w00 + vb*w10 + vc*w01 + vd*w11;
      out[idx+cidx] = (uint8_t)std::clamp<int>((int)res, 0, 255);
    }
  }
  return out;
}

// Simple joystick view that keeps last position (0..1 in view space)
@interface JoystickView : NSView
@property (nonatomic) CGPoint pos;
@end

@implementation JoystickView
- (BOOL)isFlipped { return YES; }
- (void)mouseDown:(NSEvent*)event { [self updatePos:event]; }
- (void)mouseDragged:(NSEvent*)event { [self updatePos:event]; }
- (void)updatePos:(NSEvent*)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat x = std::clamp((double)p.x / std::max(1.0, (double)self.bounds.size.width), 0.0, 1.0);
  CGFloat y = std::clamp((double)p.y / std::max(1.0, (double)self.bounds.size.height), 0.0, 1.0);
  self.pos = CGPointMake(x, y);
  [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirty {
  [[NSColor colorWithCalibratedWhite:0.1 alpha:1.0] setFill];
  NSRectFill(self.bounds);
  [[NSColor colorWithCalibratedWhite:0.3 alpha:1.0] setStroke];
  NSBezierPath* grid = [NSBezierPath bezierPath];
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  [grid moveToPoint:NSMakePoint(w*0.5, 0)]; [grid lineToPoint:NSMakePoint(w*0.5, h)];
  [grid moveToPoint:NSMakePoint(0, h*0.5)]; [grid lineToPoint:NSMakePoint(w, h*0.5)];
  [grid setLineWidth:1.0];
  [grid stroke];
  NSBezierPath* dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(self.pos.x*w - 6, self.pos.y*h - 6, 12, 12)];
  [[NSColor colorWithCalibratedRed:0.9 green:0.3 blue:0.7 alpha:1.0] setFill];
  [dot fill];
}
@end

struct Preset {
  std::string name;
  std::string plugin_path;
  std::string effect_path; // optional
  std::string sequence_dir; // optional folder of frames frame_XXXX.png
};

struct Category {
  std::string name;
  std::vector<Preset> presets;
};

struct Tile {
  std::string label;
  std::vector<Preset> presets; // active category presets
  size_t preset_index = 0;
  std::string sequence_dir;
  ImageSequence sequence;
  std::string last_frame_path;
  std::vector<uint8_t> cached_frame_bytes;
  PluginInstance primary;
  PluginInstance effect; // optional, if instanced
  NSImageView* view = nil;
  NSPopUpButton* catBtn = nil;
  NSPopUpButton* presetBtn = nil;
  size_t category_index = 0;
  id<MTLTexture> lastTex = nil;
  id<MTLTexture> reusableTex = nil;
};

static std::vector<uint8_t> load_image_scaled_cached(Tile& tile, const std::string& path, uint32_t w, uint32_t h) {
  if (path.empty()) { tile.cached_frame_bytes.clear(); tile.last_frame_path.clear(); return {}; }
  if (tile.last_frame_path == path && !tile.cached_frame_bytes.empty()) return tile.cached_frame_bytes;
  tile.cached_frame_bytes = load_image_scaled(path, w, h);
  tile.last_frame_path = path;
  return tile.cached_frame_bytes;
}

static PluginInstance make_instance(PluginLibrary& lib) {
  PluginInstance pi;
  pi.lib = &lib;
  pi.inst = lib.create_instance();
  return pi;
}

static std::vector<Tile>* gTiles = nullptr;
static std::vector<Category>* gCategories = nullptr;
static LibraryCache* gCache = nullptr;
static std::function<bool(Tile&, const Preset&)> gApplyPreset;

static void update_preset_menu(Tile& t) {
  if (!t.presetBtn) return;
  [t.presetBtn removeAllItems];
  for (const auto& p : t.presets) {
    [t.presetBtn addItemWithTitle:[NSString stringWithUTF8String:p.name.c_str()]];
  }
  [t.presetBtn selectItemAtIndex:(NSInteger)t.preset_index];
}

// Action handler to bridge UI callbacks
@interface GridActionHandler : NSObject
@end

@implementation GridActionHandler
- (void)onCategoryChanged:(id)sender {
  if (!gTiles || !gCategories) return;
  NSInteger idx = [sender tag];
  if (idx < 0 || idx >= (NSInteger)gTiles->size()) return;
  Tile& t = (*gTiles)[idx];
  NSInteger catIdx = [sender indexOfSelectedItem];
  if (catIdx < 0 || catIdx >= (NSInteger)gCategories->size()) return;
  t.category_index = (size_t)catIdx;
  t.presets = (*gCategories)[catIdx].presets;
  t.preset_index = 0;
  update_preset_menu(t);
  if (gApplyPreset) gApplyPreset(t, t.presets[t.preset_index]);
}
- (void)onPresetChanged:(id)sender {
  if (!gTiles) return;
  NSInteger idx = [sender tag];
  if (idx < 0 || idx >= (NSInteger)gTiles->size()) return;
  Tile& t = (*gTiles)[idx];
  NSInteger pIdx = [sender indexOfSelectedItem];
  if (pIdx < 0 || pIdx >= (NSInteger)t.presets.size()) return;
  t.preset_index = (size_t)pIdx;
  if (gApplyPreset) gApplyPreset(t, t.presets[t.preset_index]);
}
@end

int main(int argc, char** argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { host_log_error("No Metal device."); return 1; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) { host_log_error("No command queue."); return 1; }

    std::filesystem::path root = std::filesystem::current_path();
    auto p = [&](const char* rel){ return (root / rel).string(); };
    ConfigData cfg = load_config(root / "Media/config.json");

    LibraryCache cache;
    gCache = &cache;

    const uint32_t tileW = 480, tileH = 270;
    const uint32_t mixW = 960, mixH = 540;

    NSRect gridRect = NSMakeRect(0, 0, tileW*3 + 40, tileH*3 + 120);
    NSWindow* gridWin = [[NSWindow alloc] initWithContentRect:gridRect
                                                    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    [gridWin setTitle:@"VJ Grid"];
    NSView* content = [gridWin contentView];

    std::vector<Category> categories = {
      { "Video",
        { {"Aucun (noir)", "", "", ""},   // écran noir
          {"Video Player", "", "", ""},   // path resolved per vignette (env or fallback)
          {"Video Alt", "", "", ""} } },
      { "Generatif",
        { {"Aucun (noir)", "", "", ""},
          {"Mandala", p("Build/Plugins/libMandalaGen.dylib"), "", ""},
          {"Point Cloud", p("Build/Plugins/libPointCloud.dylib"), "", ""},
          {"Wireframe", p("Build/Plugins/libWireframe.dylib"), "", ""} } },
      { "Texte",
        { {"Aucun (noir)", "", "", ""},
          {"Text FX 1", p("Build/Plugins/libTextFX.dylib"), "", ""},
          {"Text FX Glow", p("Build/Plugins/libTextFX.dylib"), p("Build/Plugins/libTranceGlow.dylib"), ""} } },
    };

    std::vector<Tile> tiles(9);
    gTiles = &tiles;
    gCategories = &categories;

    gApplyPreset = [&](Tile& t, const Preset& preset)->bool{
      if (t.primary.inst) t.primary.destroy();
      if (t.effect.inst) t.effect.destroy();
      t.sequence_dir = preset.sequence_dir;
      t.sequence = load_sequence(t.sequence_dir);
      if (!preset.plugin_path.empty()) {
        PluginLibrary* libMain = cache.get(preset.plugin_path);
        if (!libMain) { host_log_warn(("Cannot load " + preset.plugin_path).c_str()); return false; }
        t.primary = make_instance(*libMain);
      }
      t.label = preset.name;
      if (t.presetBtn) [t.presetBtn selectItemAtIndex:(NSInteger)t.preset_index];
      return true;
    };

    GridActionHandler* handler = [GridActionHandler new];

    auto place_tile = [&](int idx)->void{
      Tile t;
      t.category_index = 0;
      t.presets = categories[0].presets;
      t.preset_index = idx % t.presets.size();
      // Assign per-tile fallback sequences for video presets
      for (auto& pr : t.presets) {
        if (pr.name == "Video Player") {
          pr.sequence_dir = env_or_config_seq(idx, cfg.tileSeqs, "Media/Tile" + std::to_string(idx + 1));
        } else if (pr.name == "Video Alt") {
          pr.sequence_dir = env_or_config_seq(idx, cfg.tileSeqs, "Media/Tile" + std::to_string(idx + 1));
        } else if (pr.name == "Aucun" || pr.name == "Aucun (noir)") {
          pr.sequence_dir = "";
        }
      }
      gApplyPreset(t, t.presets[t.preset_index]);
      int row = idx / 3;
      int col = idx % 3;
      CGFloat x = 10 + col * (tileW + 10);
      CGFloat y = 10 + row * (tileH + 60);
      NSImageView* iv = [[NSImageView alloc] initWithFrame:NSMakeRect(x, y, tileW, tileH)];
      [iv setImageScaling:NSImageScaleAxesIndependently];
      [iv setEditable:NO];
      [content addSubview:iv];
      NSPopUpButton* cat = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y+tileH+6, tileW*0.5-4, 24) pullsDown:NO];
      for (const auto& c : categories) [cat addItemWithTitle:[NSString stringWithUTF8String:c.name.c_str()]];
      [cat selectItemAtIndex:(NSInteger)t.category_index];
      [cat setTarget:handler];
      [cat setAction:@selector(onCategoryChanged:)];
      [cat setTag:idx];
      [content addSubview:cat];
      NSPopUpButton* preset = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x+tileW*0.5+4, y+tileH+6, tileW*0.5-4, 24) pullsDown:NO];
      for (const auto& pr : t.presets) [preset addItemWithTitle:[NSString stringWithUTF8String:pr.name.c_str()]];
      [preset selectItemAtIndex:(NSInteger)t.preset_index];
      [preset setTarget:handler];
      [preset setAction:@selector(onPresetChanged:)];
      [preset setTag:idx];
      [content addSubview:preset];
      t.view = iv;
      t.catBtn = cat;
      t.presetBtn = preset;
      tiles[idx] = t;
    };

    for (int i=0;i<9;++i) place_tile(i);

  JoystickView* joy = [[JoystickView alloc] initWithFrame:NSMakeRect(gridRect.size.width - 140, gridRect.size.height - 140, 120, 120)];
  joy.pos = CGPointMake(0.5, 0.5);
  [content addSubview:joy];

    [gridWin makeKeyAndOrderFront:nil];
    [gridWin center];

    NSWindow* mixWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,mixW, mixH)
                                                   styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [mixWin setTitle:@"Mix Output"];
    NSImageView* mixView = [[NSImageView alloc] initWithFrame:NSMakeRect(0,0,mixW,mixH)];
    [mixView setImageScaling:NSImageScaleAxesIndependently];
    [mixWin setContentView:mixView];
    [mixWin makeKeyAndOrderFront:nil];
    [mixWin center];
    [NSApp activateIgnoringOtherApps:YES];

    auto pump = [&](bool& changed){
      NSEvent* event = nil;
      while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                         untilDate:[NSDate dateWithTimeIntervalSinceNow:0]
                                            inMode:NSDefaultRunLoopMode
                                           dequeue:YES])) {
        if (event.type == NSEventTypeKeyDown) {
          NSString* chars = [event charactersIgnoringModifiers];
          if ([chars length] > 0) {
            unichar c = [chars characterAtIndex:0];
            if (c >= '1' && c <= '9') {
              int idx = (int)(c - '1');
              if (idx >=0 && idx < (int)tiles.size()) {
                Tile& t = tiles[idx];
                if (!t.presets.empty()) {
                  t.preset_index = (t.preset_index + 1) % t.presets.size();
                  if (gApplyPreset) gApplyPreset(t, t.presets[t.preset_index]);
                  if (t.presetBtn) [t.presetBtn selectItemAtIndex:(NSInteger)t.preset_index];
                  changed = true;
                  continue;
                }
              }
            }
          }
        }
        [NSApp sendEvent:event];
      }
    };

    double t0 = CFAbsoluteTimeGetCurrent();
    uint64_t frame = 0;
    while (gridWin && mixWin && [gridWin isVisible] && [mixWin isVisible]) {
      bool changed = false;
      pump(changed);
      double now = CFAbsoluteTimeGetCurrent();
      double t = now - t0;

      for (size_t i = 0; i < tiles.size(); ++i) {
        Tile& tile = tiles[i];
        id<MTLTexture> sourceTex = nil;
        if (tile.sequence.valid()) {
          std::string framePath = tile.sequence.frame_for_time(t);
          auto bytes = load_image_scaled_cached(tile, framePath, tileW, tileH);
          if (!bytes.empty()) {
            if (!tile.reusableTex) tile.reusableTex = make_texture(device, tileW, tileH);
            sourceTex = tile.reusableTex;
            if (sourceTex) {
              MTLRegion region = MTLRegionMake2D(0, 0, tileW, tileH);
              [sourceTex replaceRegion:region mipmapLevel:0 withBytes:bytes.data() bytesPerRow:tileW*4];
            }
          } else {
            sourceTex = tile.reusableTex; // may hold previous frame if cached was empty
          }
        }

        id<MTLTexture> texOut = sourceTex;
        if (!texOut && tile.primary.inst) {
          texOut = render_once(tile.primary, device, queue, tileW, tileH, t, nil, nil);
        }

        if (!texOut) texOut = make_texture(device, tileW, tileH);
        tile.lastTex = texOut;
        auto bytes = read_texture_bytes(texOut);
        NSImage* img = bytes_to_image(bytes, tileW, tileH);
        if (img && tile.view) [tile.view setImage:img];
      }

      if (tiles[0].lastTex && tiles[2].lastTex && tiles[6].lastTex && tiles[8].lastTex) {
        auto a = read_texture_bytes(tiles[0].lastTex);
        auto b = read_texture_bytes(tiles[2].lastTex);
        auto c = read_texture_bytes(tiles[6].lastTex);
        auto d = read_texture_bytes(tiles[8].lastTex);
        float u = joy.pos.x;
        float v = 1.0f - joy.pos.y; // flip so haut=haut (top rows)
        auto mixed = mix_four(a,b,c,d,tileW,tileH,u,v);
        NSImage* mixImg = bytes_to_image(mixed, tileW, tileH);
        if (mixImg) [mixView setImage:mixImg];
      }

      frame++;
      std::this_thread::sleep_for(std::chrono::milliseconds(33));
    }
  }
  return 0;
}
