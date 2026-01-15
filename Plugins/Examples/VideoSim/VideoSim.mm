#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <algorithm>
#include <cmath>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

struct VideoSimInstance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;
  float speed = 1.0f;
  float hue_shift = 0.0f;
};

static vj_param_desc_t g_params[] = {
  { .id="speed", .label="Speed", .type=VJ_PARAM_FLOAT, .f_min=0.1f, .f_max=4.0f, .f_default=1.0f },
  { .id="hue",   .label="Hue",   .type=VJ_PARAM_FLOAT, .f_min=0.0f, .f_max=1.0f, .f_default=0.0f },
};

static uint32_t get_count(vj_plugin_instance_t*) { return 2; }
static const vj_param_desc_t* get_desc(vj_plugin_instance_t*, uint32_t i){ return (i < 2) ? &g_params[i] : nullptr; }
static void set_param(vj_plugin_instance_t* inst,const char* id,vj_param_value_t v){
  auto* self=(VideoSimInstance*)inst;
  if (id_eq(id,"speed") && v.type==VJ_PARAM_FLOAT) self->speed = v.f;
  else if (id_eq(id,"hue") && v.type==VJ_PARAM_FLOAT) self->hue_shift = v.f;
}
static vj_param_value_t get_param(vj_plugin_instance_t* inst,const char* id){
  auto* self=(VideoSimInstance*)inst;
  if (id_eq(id,"speed")) return make_float(self->speed);
  if (id_eq(id,"hue"))   return make_float(self->hue_shift);
  return make_float(0.f);
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
  auto* self=(VideoSimInstance*)inst;
  if(!ctx||!ctx->device||!ctx->output) return;
  id<MTLTexture> outTex=(__bridge id<MTLTexture>)ctx->output;
  const uint32_t w = ctx->width;
  const uint32_t h = ctx->height;
  if (w == 0 || h == 0) return;

  std::vector<uint8_t> bytes(w * h * 4, 0);
  float t = (float)ctx->time_seconds * self->speed;
  for (uint32_t y=0; y<h; ++y) {
    for (uint32_t x=0; x<w; ++x) {
      float fx = (float)x / std::max(1u, w-1);
      float fy = (float)y / std::max(1u, h-1);
      float stripe = sinf((fx*12.0f + t*2.0f) * 3.14159f * 2.0f);
      float wave   = sinf((fy*6.0f + t*1.3f) * 3.14159f * 2.0f);
      float v = 0.5f + 0.5f * stripe * wave;
      float hue = fmodf(self->hue_shift + 0.15f * fx + 0.1f * sinf(t*0.5f), 1.0f);
      float r,g,b; hsv_to_rgb(hue, 0.8f, v, r,g,b);
      uint8_t rr = (uint8_t)std::clamp<int>((int)(r*255),0,255);
      uint8_t gg = (uint8_t)std::clamp<int>((int)(g*255),0,255);
      uint8_t bb = (uint8_t)std::clamp<int>((int)(b*255),0,255);
      size_t idx = (y*w + x)*4;
      bytes[idx+0]=bb;
      bytes[idx+1]=gg;
      bytes[idx+2]=rr;
      bytes[idx+3]=255;
    }
  }
  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [outTex replaceRegion:region mipmapLevel:0 withBytes:bytes.data() bytesPerRow:w*4];
}

static vj_plugin_instance_t* create(const vj_host_api_t* host){
  auto* inst=new VideoSimInstance(); inst->host=host; return (vj_plugin_instance_t*)inst;
}
static void destroy(vj_plugin_instance_t* instance){ delete (VideoSimInstance*)instance; }

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.videosim",
  .name = "Video Sim",
  .vendor = "OpenVJ Starter",
  .description = "Simulated video generator (moving bars/waves).",
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
