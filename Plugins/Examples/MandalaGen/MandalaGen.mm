#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

struct MandalaGenInstance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;

  int symmetry = 8;
  float spin = 1.0f;
  float zoom = 1.0f;
  float complexity = 0.5f;
  vj_color_t colorA = {0.2f, 0.9f, 1.0f, 1.f};
  vj_color_t colorB = {1.0f, 0.2f, 0.9f, 1.f};

  id<MTLLibrary> library = nil;
  id<MTLRenderPipelineState> pso = nil;

  void ensurePipeline(id<MTLDevice> device, MTLPixelFormat fmt) {
    if (pso) return;
    NSError* err = nil;
    NSString* src = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VSOut {
  float4 position [[position]];
  float2 uv;
};

vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
  float2 pos;
  pos.x = (vid == 2) ?  3.0 : -1.0;
  pos.y = (vid == 1) ?  3.0 : -1.0;

  VSOut o;
  o.position = float4(pos, 0.0, 1.0);
  o.uv = 0.5 * (pos + 1.0);
  return o;
}

struct Params {
  int symmetry;
  float spin;
  float zoom;
  float complexity;
  float4 colorA;
  float4 colorB;
  float time;
  float2 size;
};

inline float hash21(float2 p) {
  p = fract(p*float2(123.34, 456.21));
  p += dot(p, p+78.233);
  return fract(p.x*p.y);
}

inline float2 rot(float2 p, float a) {
  float ca = cos(a), sa = sin(a);
  return float2(p.x*ca - p.y*sa, p.x*sa + p.y*ca);
}

fragment float4 fs_mandala(VSOut in [[stage_in]],
                           constant Params& p [[buffer(0)]]) {
  float2 uv = in.uv;
  float2 c = (uv - 0.5) * 2.0;
  c.x *= p.size.x / max(1.0, p.size.y);

  c = rot(c, p.time * p.spin * 0.2);
  c /= max(0.001, p.zoom);

  float r = length(c);
  float a = atan2(c.y, c.x);

  // Symmetry: fold angle
  float n = max(1.0, (float)p.symmetry);
  float seg = 6.28318530718 / n;
  a = fmod(a, seg);
  a = abs(a - seg*0.5);

  // Procedural pattern
  float waves = sin(a * (6.0 + p.complexity*12.0) + p.time * p.spin) * 0.5 + 0.5;
  float rings = sin(r * (10.0 + p.complexity*30.0) - p.time) * 0.5 + 0.5;

  float m = pow(waves * rings, 1.2);
  float glow = exp(-r*r*1.5) * 0.8;

  float t = clamp(m + glow, 0.0, 1.0);
  float3 col = mix(p.colorA.rgb, p.colorB.rgb, t);

  // Soft vignette
  col *= (1.0 - smoothstep(0.9, 1.5, r));

  return float4(col, 1.0);
}
)METAL";
    library = [device newLibraryWithSource:src options:nil error:&err];
    if (!library) {
      if (host && host->log_error) host->log_error([[err localizedDescription] UTF8String]);
      return;
    }
    id<MTLFunction> vs = [library newFunctionWithName:@"vs_fullscreen"];
    id<MTLFunction> fs = [library newFunctionWithName:@"fs_mandala"];

    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vs;
    desc.fragmentFunction = fs;
    desc.colorAttachments[0].pixelFormat = fmt;

    pso = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!pso) {
      if (host && host->log_error) host->log_error([[err localizedDescription] UTF8String]);
    }
  }
};

static vj_param_desc_t g_params[] = {
  {
    .id="symmetry", .label="Symmetry", .type=VJ_PARAM_INT,
    .i_min=1, .i_max=32, .i_default=8,
  },
  {
    .id="spin", .label="Spin", .type=VJ_PARAM_FLOAT,
    .f_min=0.0f, .f_max=5.0f, .f_default=1.0f,
  },
  {
    .id="zoom", .label="Zoom", .type=VJ_PARAM_FLOAT,
    .f_min=0.2f, .f_max=4.0f, .f_default=1.0f,
  },
  {
    .id="complexity", .label="Complexity", .type=VJ_PARAM_FLOAT,
    .f_min=0.0f, .f_max=1.0f, .f_default=0.5f,
  },
  {
    .id="colorA", .label="Color A", .type=VJ_PARAM_COLOR,
    .color_default={0.2f,0.9f,1.0f,1.f},
  },
  {
    .id="colorB", .label="Color B", .type=VJ_PARAM_COLOR,
    .color_default={1.0f,0.2f,0.9f,1.f},
  },
};

static uint32_t mandala_get_param_count(vj_plugin_instance_t*) {
  return (uint32_t)(sizeof(g_params)/sizeof(g_params[0]));
}

static const vj_param_desc_t* mandala_get_param_desc(vj_plugin_instance_t*, uint32_t index) {
  if (index >= mandala_get_param_count(nullptr)) return nullptr;
  return &g_params[index];
}

static void mandala_set_param(vj_plugin_instance_t* inst, const char* param_id, vj_param_value_t value) {
  auto* self = (MandalaGenInstance*)inst;
  if (id_eq(param_id,"symmetry") && value.type==VJ_PARAM_INT) self->symmetry = value.i;
  else if (id_eq(param_id,"spin") && value.type==VJ_PARAM_FLOAT) self->spin = value.f;
  else if (id_eq(param_id,"zoom") && value.type==VJ_PARAM_FLOAT) self->zoom = value.f;
  else if (id_eq(param_id,"complexity") && value.type==VJ_PARAM_FLOAT) self->complexity = value.f;
  else if (id_eq(param_id,"colorA") && value.type==VJ_PARAM_COLOR) self->colorA = value.color;
  else if (id_eq(param_id,"colorB") && value.type==VJ_PARAM_COLOR) self->colorB = value.color;
}

static vj_param_value_t mandala_get_param(vj_plugin_instance_t* inst, const char* param_id) {
  auto* self = (MandalaGenInstance*)inst;
  if (id_eq(param_id,"symmetry")) return make_int(self->symmetry);
  if (id_eq(param_id,"spin")) return make_float(self->spin);
  if (id_eq(param_id,"zoom")) return make_float(self->zoom);
  if (id_eq(param_id,"complexity")) return make_float(self->complexity);
  if (id_eq(param_id,"colorA")) return make_color(self->colorA.r,self->colorA.g,self->colorA.b,self->colorA.a);
  if (id_eq(param_id,"colorB")) return make_color(self->colorB.r,self->colorB.g,self->colorB.b,self->colorB.a);
  return make_float(0.f);
}

typedef struct Params {
  int32_t symmetry;
  float spin;
  float zoom;
  float complexity;
  float colorA[4];
  float colorB[4];
  float time;
  float size[2];
} Params;

static void mandala_render(vj_plugin_instance_t* inst, const vj_render_context_t* ctx) {
  auto* self = (MandalaGenInstance*)inst;
  if (!ctx || !ctx->device || !ctx->command_buffer || !ctx->output) return;

  id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
  id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)ctx->command_buffer;
  id<MTLTexture> outTex = (__bridge id<MTLTexture>)ctx->output;

  MTLPixelFormat fmt = outTex.pixelFormat;
  self->ensurePipeline(device, fmt);
  if (!self->pso) return;

  MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = outTex;
  rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:self->pso];

  Params p;
  p.symmetry = self->symmetry;
  p.spin = self->spin;
  p.zoom = self->zoom;
  p.complexity = self->complexity;
  p.colorA[0]=self->colorA.r; p.colorA[1]=self->colorA.g; p.colorA[2]=self->colorA.b; p.colorA[3]=self->colorA.a;
  p.colorB[0]=self->colorB.r; p.colorB[1]=self->colorB.g; p.colorB[2]=self->colorB.b; p.colorB[3]=self->colorB.a;
  p.time = (float)ctx->time_seconds;
  p.size[0]=(float)ctx->width; p.size[1]=(float)ctx->height;

  [enc setFragmentBytes:&p length:sizeof(Params) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];
}

static vj_plugin_instance_t* mandala_create(const vj_host_api_t* host) {
  auto* inst = new MandalaGenInstance();
  inst->host = host;
  if (host && host->log_info) host->log_info("MandalaGen: created");
  return (vj_plugin_instance_t*)inst;
}

static void mandala_destroy(vj_plugin_instance_t* instance) {
  auto* self = (MandalaGenInstance*)instance;
  if (!self) return;
  self->pso = nil;
  self->library = nil;
  if (self->host && self->host->log_info) self->host->log_info("MandalaGen: destroyed");
  delete self;
}

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.mandalagen",
  .name = "Mandala Generator",
  .vendor = "OpenVJ Starter",
  .description = "Procedural mandala generator (Metal shader).",
  .kind = VJ_PLUGIN_GENERATOR,

  .create = mandala_create,
  .destroy = mandala_destroy,

  .get_param_count = mandala_get_param_count,
  .get_param_desc  = mandala_get_param_desc,
  .set_param       = mandala_set_param,
  .get_param       = mandala_get_param,

  .render = mandala_render,
};

extern "C" const vj_plugin_descriptor_t* vj_plugin_get_descriptor(void) {
  return &g_desc;
}
