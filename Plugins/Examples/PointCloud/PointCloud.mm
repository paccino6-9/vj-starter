#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <random>
#include <algorithm>
#include <cmath>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

struct Particle { float x, y, vx, vy; float hue; };

struct PointCloudInstance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;
  std::vector<Particle> pts;
  float speed = 1.0f;
  float spread = 0.4f;

  void init_particles(uint32_t count) {
    std::mt19937 rng(42);
    std::uniform_real_distribution<float> r01(0.f, 1.f);
    pts.resize(count);
    for (auto& p : pts) {
      p.x = r01(rng) * 2.f - 1.f;
      p.y = r01(rng) * 2.f - 1.f;
      p.vx = (r01(rng) - 0.5f) * 0.2f;
      p.vy = (r01(rng) - 0.5f) * 0.2f;
      p.hue = r01(rng);
    }
  }
};

static vj_param_desc_t g_params[] = {
  { .id="speed", .label="Speed", .type=VJ_PARAM_FLOAT, .f_min=0.1f, .f_max=4.0f, .f_default=1.0f },
  { .id="spread", .label="Spread", .type=VJ_PARAM_FLOAT, .f_min=0.1f, .f_max=1.5f, .f_default=0.4f },
};

static uint32_t get_count(vj_plugin_instance_t*) { return 2; }
static const vj_param_desc_t* get_desc(vj_plugin_instance_t*, uint32_t i){ return (i < 2) ? &g_params[i] : nullptr; }
static void set_param(vj_plugin_instance_t* inst,const char* id,vj_param_value_t v){
  auto* self=(PointCloudInstance*)inst;
  if (id_eq(id,"speed") && v.type==VJ_PARAM_FLOAT) self->speed = v.f;
  else if (id_eq(id,"spread") && v.type==VJ_PARAM_FLOAT) self->spread = v.f;
}
static vj_param_value_t get_param(vj_plugin_instance_t* inst,const char* id){
  auto* self=(PointCloudInstance*)inst;
  if (id_eq(id,"speed")) return make_float(self->speed);
  if (id_eq(id,"spread")) return make_float(self->spread);
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
  auto* self=(PointCloudInstance*)inst;
  if(!ctx||!ctx->device||!ctx->output) return;
  id<MTLTexture> outTex=(__bridge id<MTLTexture>)ctx->output;
  const uint32_t w = ctx->width;
  const uint32_t h = ctx->height;
  if (w == 0 || h == 0) return;

  if (self->pts.empty()) self->init_particles(1200);

  std::vector<uint8_t> bytes(w * h * 4, 0);
  float t = (float)ctx->time_seconds * self->speed;

  // Update positions and draw points as bright dots
  for (auto& p : self->pts) {
    p.x += p.vx * 0.01f * self->speed;
    p.y += p.vy * 0.01f * self->speed;
    p.x = fmodf(p.x + 3.f, 2.f) - 1.f;
    p.y = fmodf(p.y + 3.f, 2.f) - 1.f;
    float px = (p.x * self->spread) + 0.5f;
    float py = (p.y * self->spread) + 0.5f;
    int ix = (int)(px * (float)(w-1));
    int iy = (int)(py * (float)(h-1));
    if (ix < 0 || iy < 0 || ix >= (int)w || iy >= (int)h) continue;
    float r,g,b; hsv_to_rgb(p.hue + 0.1f*t, 0.9f, 1.0f, r,g,b);
    size_t idx = (iy*w + ix)*4;
    bytes[idx+0] = (uint8_t)std::clamp<int>((int)(b*255),0,255);
    bytes[idx+1] = (uint8_t)std::clamp<int>((int)(g*255),0,255);
    bytes[idx+2] = (uint8_t)std::clamp<int>((int)(r*255),0,255);
    bytes[idx+3] = 255;
  }

  // Simple blur-ish glow by copying to neighbors
  std::vector<uint8_t> blurred(bytes.size(), 0);
  auto idx = [&](int x,int y){ return (y*w + x)*4; };
  for (uint32_t y=1; y+1<h; ++y) {
    for (uint32_t x=1; x+1<w; ++x) {
      size_t i = idx(x,y);
      for (int c=0;c<3;++c) {
        int sum = bytes[idx(x,y)+c] + bytes[idx(x-1,y)+c] + bytes[idx(x+1,y)+c] +
                  bytes[idx(x,y-1)+c] + bytes[idx(x,y+1)+c];
        blurred[i+c] = (uint8_t)std::min(sum/5, 255);
      }
      blurred[i+3] = 255;
    }
  }

  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [outTex replaceRegion:region mipmapLevel:0 withBytes:blurred.data() bytesPerRow:w*4];
}

static vj_plugin_instance_t* create(const vj_host_api_t* host){
  auto* inst=new PointCloudInstance(); inst->host=host; return (vj_plugin_instance_t*)inst;
}
static void destroy(vj_plugin_instance_t* instance){ delete (PointCloudInstance*)instance; }

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.pointcloud",
  .name = "Point Cloud",
  .vendor = "OpenVJ Starter",
  .description = "Nuée de points animés.",
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
