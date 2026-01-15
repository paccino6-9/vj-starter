#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

// ---------------- Plugin instance ----------------

struct TranceGlowInstance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;

  // Params
  float amount = 0.8f;
  float speed  = 1.0f;
  float zoom   = 1.0f;
  bool posterize = false;
  vj_color_t tint = {1.f, 1.f, 1.f, 1.f};

  // Metal cached objects
  id<MTLLibrary> library = nil;
  id<MTLRenderPipelineState> pso = nil;

  uint32_t lastW = 0;
  uint32_t lastH = 0;

  void log(const char* msg) {
    if (host && host->log_info) host->log_info(msg);
  }

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
  // Full-screen triangle
  float2 pos;
  pos.x = (vid == 2) ?  3.0 : -1.0;
  pos.y = (vid == 1) ?  3.0 : -1.0;

  VSOut o;
  o.position = float4(pos, 0.0, 1.0);
  o.uv = 0.5 * (pos + 1.0);
  return o;
}

struct Params {
  float amount;
  float speed;
  float zoom;
  uint  posterize;
  float4 tint;
  float time;
  float2 size;
};

inline float3 sampleTex(texture2d<float> tex, sampler s, float2 uv) {
  return tex.sample(s, uv).rgb;
}

fragment float4 fs_trance_glow(VSOut in [[stage_in]],
                               constant Params& p [[buffer(0)]],
                               texture2d<float> src [[texture(0)]]) {
  constexpr sampler s(address::clamp_to_edge, filter::linear);

  // Centered coords
  float2 uv = in.uv;
  float2 c = uv - 0.5;

  // rotation
  float a = p.time * p.speed * 0.2;
  float ca = cos(a), sa = sin(a);
  float2 cr = float2(c.x * ca - c.y * sa, c.x * sa + c.y * ca);

  // zoom
  cr /= max(0.001, p.zoom);

  float2 uvr = cr + 0.5;

  float3 base = sampleTex(src, s, uvr);

  // fake glow: sample a few offsets
  float2 px = 1.0 / max(p.size, float2(1.0));
  float3 blur =
      sampleTex(src,s,uvr + px*float2( 1, 0)) +
      sampleTex(src,s,uvr + px*float2(-1, 0)) +
      sampleTex(src,s,uvr + px*float2( 0, 1)) +
      sampleTex(src,s,uvr + px*float2( 0,-1)) +
      sampleTex(src,s,uvr + px*float2( 1, 1)) +
      sampleTex(src,s,uvr + px*float2(-1,-1));
  blur /= 6.0;

  float3 glow = base + blur * 0.8;

  float3 col = mix(base, glow, clamp(p.amount, 0.0, 1.0));
  col *= p.tint.rgb;

  if (p.posterize != 0) {
    float steps = 6.0;
    col = floor(col * steps) / steps;
  }

  // mild contrast
  col = pow(col, float3(0.9));

  return float4(col, 1.0);
}
)METAL";

    MTLCompileOptions* opt = [MTLCompileOptions new];
    library = [device newLibraryWithSource:src options:opt error:&err];
    if (!library) {
      if (host && host->log_error) {
        const char* e = [[err localizedDescription] UTF8String];
        host->log_error(e ? e : "Metal compile error");
      }
      return;
    }

    id<MTLFunction> vs = [library newFunctionWithName:@"vs_fullscreen"];
    id<MTLFunction> fs = [library newFunctionWithName:@"fs_trance_glow"];

    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vs;
    desc.fragmentFunction = fs;
    desc.colorAttachments[0].pixelFormat = fmt;

    pso = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!pso) {
      if (host && host->log_error) {
        const char* e = [[err localizedDescription] UTF8String];
        host->log_error(e ? e : "Metal PSO error");
      }
    }
  }
};

static const char* kEnumEmpty[] = { };

static vj_param_desc_t g_params[] = {
  {
    .id="amount", .label="Amount", .type=VJ_PARAM_FLOAT,
    .f_min=0.0f, .f_max=1.0f, .f_default=0.8f,
  },
  {
    .id="speed", .label="Speed", .type=VJ_PARAM_FLOAT,
    .f_min=0.0f, .f_max=5.0f, .f_default=1.0f,
  },
  {
    .id="zoom", .label="Zoom", .type=VJ_PARAM_FLOAT,
    .f_min=0.2f, .f_max=3.0f, .f_default=1.0f,
  },
  {
    .id="posterize", .label="Posterize", .type=VJ_PARAM_BOOL,
    .b_default=0,
  },
  {
    .id="tint", .label="Tint", .type=VJ_PARAM_COLOR,
    .color_default={1.f,1.f,1.f,1.f},
  },
};

static uint32_t trance_get_param_count(vj_plugin_instance_t* ) {
  return (uint32_t)(sizeof(g_params)/sizeof(g_params[0]));
}

static const vj_param_desc_t* trance_get_param_desc(vj_plugin_instance_t*, uint32_t index) {
  if (index >= trance_get_param_count(nullptr)) return nullptr;
  return &g_params[index];
}

static void trance_set_param(vj_plugin_instance_t* inst, const char* param_id, vj_param_value_t value) {
  auto* self = (TranceGlowInstance*)inst;
  if (id_eq(param_id, "amount") && value.type==VJ_PARAM_FLOAT) self->amount = value.f;
  else if (id_eq(param_id, "speed") && value.type==VJ_PARAM_FLOAT) self->speed = value.f;
  else if (id_eq(param_id, "zoom") && value.type==VJ_PARAM_FLOAT) self->zoom = value.f;
  else if (id_eq(param_id, "posterize") && value.type==VJ_PARAM_BOOL) self->posterize = (value.b!=0);
  else if (id_eq(param_id, "tint") && value.type==VJ_PARAM_COLOR) self->tint = value.color;
}

static vj_param_value_t trance_get_param(vj_plugin_instance_t* inst, const char* param_id) {
  auto* self = (TranceGlowInstance*)inst;
  if (id_eq(param_id, "amount")) return make_float(self->amount);
  if (id_eq(param_id, "speed")) return make_float(self->speed);
  if (id_eq(param_id, "zoom")) return make_float(self->zoom);
  if (id_eq(param_id, "posterize")) return make_bool(self->posterize);
  if (id_eq(param_id, "tint")) return make_color(self->tint.r,self->tint.g,self->tint.b,self->tint.a);
  return make_float(0.f);
}

typedef struct Params {
  float amount;
  float speed;
  float zoom;
  uint32_t posterize;
  float tint[4];
  float time;
  float size[2];
} Params;

static void trance_render(vj_plugin_instance_t* inst, const vj_render_context_t* ctx) {
  auto* self = (TranceGlowInstance*)inst;
  if (!ctx || !ctx->device || !ctx->command_buffer || !ctx->output) return;
  if (ctx->input_count < 1 || !ctx->inputs[0]) return;

  id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
  id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)ctx->command_buffer;
  id<MTLTexture> inTex = (__bridge id<MTLTexture>)ctx->inputs[0];
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
  p.amount = self->amount;
  p.speed = self->speed;
  p.zoom = self->zoom;
  p.posterize = self->posterize ? 1u : 0u;
  p.tint[0]=self->tint.r; p.tint[1]=self->tint.g; p.tint[2]=self->tint.b; p.tint[3]=self->tint.a;
  p.time = (float)ctx->time_seconds;
  p.size[0]=(float)ctx->width; p.size[1]=(float)ctx->height;

  [enc setFragmentBytes:&p length:sizeof(Params) atIndex:0];
  [enc setFragmentTexture:inTex atIndex:0];

  // full-screen triangle
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];
}

static vj_plugin_instance_t* trance_create(const vj_host_api_t* host) {
  auto* inst = new TranceGlowInstance();
  inst->host = host;
  if (host && host->log_info) host->log_info("TranceGlow: created");
  return (vj_plugin_instance_t*)inst;
}

static void trance_destroy(vj_plugin_instance_t* instance) {
  auto* self = (TranceGlowInstance*)instance;
  if (!self) return;
  self->pso = nil;
  self->library = nil;
  if (self->host && self->host->log_info) self->host->log_info("TranceGlow: destroyed");
  delete self;
}

// ---------------- Descriptor ----------------

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.tranceglow",
  .name = "Trance Glow",
  .vendor = "OpenVJ Starter",
  .description = "Simple trance-style glow effect (Metal shader).",
  .kind = VJ_PLUGIN_EFFECT,

  .create = trance_create,
  .destroy = trance_destroy,

  .get_param_count = trance_get_param_count,
  .get_param_desc  = trance_get_param_desc,
  .set_param       = trance_set_param,
  .get_param       = trance_get_param,

  .render = trance_render,
};

extern "C" const vj_plugin_descriptor_t* vj_plugin_get_descriptor(void) {
  return &g_desc;
}
