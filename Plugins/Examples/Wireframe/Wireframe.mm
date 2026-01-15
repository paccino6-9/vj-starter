#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <algorithm>
#include <cmath>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

struct WireframeInstance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;
  float spin = 0.6f;
  float scale = 0.7f;
};

static vj_param_desc_t g_params[] = {
  { .id="spin",  .label="Spin",  .type=VJ_PARAM_FLOAT, .f_min=0.f, .f_max=4.f, .f_default=0.6f },
  { .id="scale", .label="Scale", .type=VJ_PARAM_FLOAT, .f_min=0.3f, .f_max=1.2f, .f_default=0.7f },
};

static uint32_t get_count(vj_plugin_instance_t*) { return 2; }
static const vj_param_desc_t* get_desc(vj_plugin_instance_t*, uint32_t i){ return (i < 2) ? &g_params[i] : nullptr; }
static void set_param(vj_plugin_instance_t* inst,const char* id,vj_param_value_t v){
  auto* self=(WireframeInstance*)inst;
  if (id_eq(id,"spin") && v.type==VJ_PARAM_FLOAT) self->spin = v.f;
  else if (id_eq(id,"scale") && v.type==VJ_PARAM_FLOAT) self->scale = v.f;
}
static vj_param_value_t get_param(vj_plugin_instance_t* inst,const char* id){
  auto* self=(WireframeInstance*)inst;
  if (id_eq(id,"spin")) return make_float(self->spin);
  if (id_eq(id,"scale")) return make_float(self->scale);
  return make_float(0.f);
}

struct Vec2 { float x,y; };
static Vec2 rot(Vec2 p, float a) {
  float c = cosf(a), s = sinf(a);
  return { p.x * c - p.y * s, p.x * s + p.y * c };
}

static void draw_line(std::vector<uint8_t>& buf, uint32_t w, uint32_t h,
                      int x0,int y0,int x1,int y1, uint8_t r,uint8_t g,uint8_t b) {
  auto put = [&](int x,int y){
    if (x < 0 || y < 0 || x >= (int)w || y >= (int)h) return;
    size_t idx = (y*w + x)*4;
    buf[idx+0]=b; buf[idx+1]=g; buf[idx+2]=r; buf[idx+3]=255;
  };
  int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
  int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
  int err = dx + dy, e2;
  while (true) {
    put(x0,y0);
    if (x0 == x1 && y0 == y1) break;
    e2 = 2*err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
}

static void render(vj_plugin_instance_t* inst, const vj_render_context_t* ctx){
  auto* self=(WireframeInstance*)inst;
  if(!ctx||!ctx->device||!ctx->output) return;
  id<MTLTexture> outTex=(__bridge id<MTLTexture>)ctx->output;
  const uint32_t w = ctx->width;
  const uint32_t h = ctx->height;
  if (w == 0 || h == 0) return;

  std::vector<uint8_t> bytes(w * h * 4, 0);
  float t = (float)ctx->time_seconds;
  float angle = t * self->spin;
  float sc = self->scale;

  // cube vertices
  Vec2 verts[8];
  int idx = 0;
  for (int sy=-1; sy<=1; sy+=2) {
    for (int sx=-1; sx<=1; sx+=2) {
      Vec2 p = { sx * sc, sy * sc * 0.7f };
      p = rot(p, angle);
      verts[idx++] = p;
    }
  }

  auto to_screen = [&](Vec2 p)->std::pair<int,int>{
    float px = (p.x*0.5f + 0.5f) * (float)(w-1);
    float py = (p.y*0.5f + 0.5f) * (float)(h-1);
    return { (int)px, (int)py };
  };

  // edges (projected quad-like wireframe)
  int edges[12][2] = {
    {0,1},{1,3},{3,2},{2,0},
    {4,5},{5,7},{7,6},{6,4},
    {0,4},{1,5},{2,6},{3,7}
  };

  for (auto& e : edges) {
    auto [x0,y0] = to_screen(verts[e[0]]);
    auto [x1,y1] = to_screen(verts[e[1]]);
    uint8_t r = (uint8_t)(128 + 80 * sinf(t + e[0]));
    uint8_t g = (uint8_t)(128 + 80 * sinf(t*0.7f + e[1]));
    uint8_t b = 220;
    draw_line(bytes, w, h, x0,y0,x1,y1, r,g,b);
  }

  // crosshair
  draw_line(bytes, w, h, w/2-20, h/2, w/2+20, h/2, 255,255,255);
  draw_line(bytes, w, h, w/2, h/2-20, w/2, h/2+20, 255,255,255);

  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [outTex replaceRegion:region mipmapLevel:0 withBytes:bytes.data() bytesPerRow:w*4];
}

static vj_plugin_instance_t* create(const vj_host_api_t* host){
  auto* inst=new WireframeInstance(); inst->host=host; return (vj_plugin_instance_t*)inst;
}
static void destroy(vj_plugin_instance_t* instance){ delete (WireframeInstance*)instance; }

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.wireframe",
  .name = "Wireframe",
  .vendor = "OpenVJ Starter",
  .description = "Squelette en fil de fer animé.",
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
