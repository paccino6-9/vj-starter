#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#include <vector>
#include <algorithm>
#include <cmath>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

static const char* kWords[] = { "VJ", "LIVE", "GROOVE", "TEXT" };

struct TextFXInstance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;
  int word_idx = 0;
  float hue = 0.55f;
};

static vj_param_desc_t g_params[] = {
  { .id="word", .label="Word", .type=VJ_PARAM_ENUM,
    .enum_labels=kWords, .enum_count=4, .i_default=0 },
  { .id="hue",  .label="Hue",  .type=VJ_PARAM_FLOAT,
    .f_min=0.f, .f_max=1.f, .f_default=0.55f },
};

static uint32_t get_count(vj_plugin_instance_t*) { return 2; }
static const vj_param_desc_t* get_desc(vj_plugin_instance_t*, uint32_t i){ return (i < 2) ? &g_params[i] : nullptr; }
static void set_param(vj_plugin_instance_t* inst,const char* id,vj_param_value_t v){
  auto* self=(TextFXInstance*)inst;
  if (id_eq(id,"word") && v.type==VJ_PARAM_ENUM) self->word_idx = (int)v.i % 4;
  else if (id_eq(id,"hue") && v.type==VJ_PARAM_FLOAT) self->hue = v.f;
}
static vj_param_value_t get_param(vj_plugin_instance_t* inst,const char* id){
  auto* self=(TextFXInstance*)inst;
  if (id_eq(id,"word")) return make_int(self->word_idx);
  if (id_eq(id,"hue"))  return make_float(self->hue);
  return make_int(0);
}

static inline void hsv_to_rgb(float h, float s, float v, float& r,float& g,float& b) {
  h = fmodf(h, 1.0f) * 6.0f;
  float c = v * s;
  float x = c * (1 - fabsf(fmodf(h, 2.0f) - 1));
  float m = v - c;
  float rr=0, gg=0, bb=0;
  if (h < 1) { rr=c; gg=x; bb=0; }
  else if (h < 2) { rr=x; gg=c; bb=0; }
  else if (h < 3) { rr=0; gg=c; bb=x; }
  else if (h < 4) { rr=0; gg=x; bb=c; }
  else if (h < 5) { rr=x; gg=0; bb=c; }
  else { rr=c; gg=0; bb=x; }
  r=rr+m; g=gg+m; b=bb+m;
}

static void render(vj_plugin_instance_t* inst, const vj_render_context_t* ctx){
  auto* self=(TextFXInstance*)inst;
  if(!ctx||!ctx->device||!ctx->output) return;
  id<MTLTexture> outTex=(__bridge id<MTLTexture>)ctx->output;
  const uint32_t w = ctx->width;
  const uint32_t h = ctx->height;
  if (w == 0 || h == 0) return;

  std::vector<uint8_t> bytes(w * h * 4, 0);

  float r,g,b; hsv_to_rgb(self->hue + 0.1f*(float)sin(ctx->time_seconds*0.5), 0.7f, 1.0f, r,g,b);
  for (uint32_t y=0; y<h; ++y) {
    float t = (float)y / std::max(1u, h-1);
    uint8_t rr = (uint8_t)std::clamp<int>((int)((r*255)*(0.6f+0.4f*(1.0f-t))),0,255);
    uint8_t gg = (uint8_t)std::clamp<int>((int)((g*255)*(0.6f+0.4f*t)),0,255);
    uint8_t bb = (uint8_t)std::clamp<int>((int)((b*255)),0,255);
    for (uint32_t x=0; x<w; ++x) {
      bytes[(y*w + x)*4 + 0] = bb;
      bytes[(y*w + x)*4 + 1] = gg;
      bytes[(y*w + x)*4 + 2] = rr;
      bytes[(y*w + x)*4 + 3] = 255;
    }
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
  bi |= (CGBitmapInfo)kCGBitmapByteOrder32Big;
  CGContextRef cg = CGBitmapContextCreate(bytes.data(), w, h, 8, w*4, cs, bi);
  if (cs) CGColorSpaceRelease(cs);
  if (cg) {
    CGContextSetAllowsAntialiasing(cg, true);
    CGContextSetShouldAntialias(cg, true);
    CGContextSetTextDrawingMode(cg, kCGTextFill);

    NSString* str = [NSString stringWithUTF8String:kWords[self->word_idx % 4]];
    CGFloat fontSize = (CGFloat)std::min(w,h) * 0.35;
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), fontSize, nullptr);
    CGFloat comps[4] = {1.0, 1.0, 1.0, 0.95};
    CGColorRef fg = CGColorCreate(cs, comps);
    const void* keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void* vals[] = { font, fg };
    CFDictionaryRef attrs = CFDictionaryCreate(nullptr, keys, vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attr = CFAttributedStringCreate(nullptr, (CFStringRef)str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attr);
    double ascent=0, descent=0, leading=0;
    double widthLine = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    double heightLine = ascent + descent + leading;
    CGPoint origin;
    origin.x = (w - widthLine) * 0.5;
    origin.y = (h - heightLine) * 0.5;
    CGFloat sh[4] = {0,0,0,0.35};
    CGColorRef shadow = CGColorCreate(cs, sh);
    CGContextSetShadowWithColor(cg, CGSizeMake(4, -4), 6.0, shadow);
    CGContextTranslateCTM(cg, 0, h);
    CGContextScaleCTM(cg, 1, -1);
    CGContextSetTextPosition(cg, origin.x, origin.y);
    CTLineDraw(line, cg);
    if (shadow) CGColorRelease(shadow);
    if (line) CFRelease(line);
    if (attr) CFRelease(attr);
    if (attrs) CFRelease(attrs);
    if (fg) CGColorRelease(fg);
    if (font) CFRelease(font);
  }

  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [outTex replaceRegion:region mipmapLevel:0 withBytes:bytes.data() bytesPerRow:w*4];
  if (cg) CGContextRelease(cg);
}

static vj_plugin_instance_t* create(const vj_host_api_t* host){
  auto* inst=new TextFXInstance(); inst->host=host; return (vj_plugin_instance_t*)inst;
}
static void destroy(vj_plugin_instance_t* instance){ delete (TextFXInstance*)instance; }

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.textfx",
  .name = "Text FX",
  .vendor = "OpenVJ Starter",
  .description = "CPU text overlay with animated background.",
  .kind = VJ_PLUGIN_GENERATOR,
  .create = create,
  .destroy = destroy,
  .get_param_count = get_count,
  .get_param_desc  = get_desc,
  .set_param       = set_param,
  .get_param       = get_param,
  .render          = render,
};

extern "C" const vj_plugin_descriptor_t* vj_plugin_get_descriptor(void){ return &g_desc; }
