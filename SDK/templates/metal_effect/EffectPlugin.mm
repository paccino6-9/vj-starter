\
/*
  Template minimal pour un plugin "Effect" Metal.
  Copie ce dossier, renomme, et change le shader.
*/
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "vj_plugin_api.h"
#include "vj_sdk.hpp"

using namespace vj;

// TODO: remplace par ton shader
static const char* kMetalSrc = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VSOut { float4 position [[position]]; float2 uv; };

vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
  float2 pos;
  pos.x = (vid == 2) ?  3.0 : -1.0;
  pos.y = (vid == 1) ?  3.0 : -1.0;
  VSOut o; o.position=float4(pos,0,1); o.uv=0.5*(pos+1.0); return o;
}

struct Params { float amount; float time; float2 size; };

fragment float4 fs_effect(VSOut in [[stage_in]],
                          constant Params& p [[buffer(0)]],
                          texture2d<float> src [[texture(0)]]) {
  constexpr sampler s(address::clamp_to_edge, filter::linear);
  float3 c = src.sample(s, in.uv).rgb;
  // TODO: do something cool
  c = mix(c, float3(1.0 - c), clamp(p.amount,0.0,1.0));
  return float4(c, 1.0);
}
)METAL";

struct Instance : vj_plugin_instance_t {
  const vj_host_api_t* host = nullptr;
  float amount = 0.5f;

  id<MTLLibrary> library = nil;
  id<MTLRenderPipelineState> pso = nil;

  void ensure(id<MTLDevice> device, MTLPixelFormat fmt) {
    if (pso) return;
    NSError* err=nil;
    NSString* src=[NSString stringWithUTF8String:kMetalSrc];
    library=[device newLibraryWithSource:src options:nil error:&err];
    if (!library) { if(host&&host->log_error) host->log_error([[err localizedDescription] UTF8String]); return; }
    id<MTLFunction> vs=[library newFunctionWithName:@"vs_fullscreen"];
    id<MTLFunction> fs=[library newFunctionWithName:@"fs_effect"];
    MTLRenderPipelineDescriptor* d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=vs; d.fragmentFunction=fs;
    d.colorAttachments[0].pixelFormat=fmt;
    pso=[device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso) { if(host&&host->log_error) host->log_error([[err localizedDescription] UTF8String]); }
  }
};

static vj_param_desc_t g_params[] = {
  { .id="amount", .label="Amount", .type=VJ_PARAM_FLOAT, .f_min=0.f, .f_max=1.f, .f_default=0.5f }
};

static uint32_t get_count(vj_plugin_instance_t*) { return 1; }
static const vj_param_desc_t* get_desc(vj_plugin_instance_t*, uint32_t i){ return (i==0)?&g_params[0]:nullptr; }
static void set_param(vj_plugin_instance_t* inst,const char* id,vj_param_value_t v){
  auto* self=(Instance*)inst; if(id_eq(id,"amount")&&v.type==VJ_PARAM_FLOAT) self->amount=v.f;
}
static vj_param_value_t get_param(vj_plugin_instance_t* inst,const char* id){
  auto* self=(Instance*)inst; if(id_eq(id,"amount")) return make_float(self->amount); return make_float(0.f);
}

typedef struct Params { float amount; float time; float size[2]; } Params;

static void render(vj_plugin_instance_t* inst, const vj_render_context_t* ctx){
  auto* self=(Instance*)inst;
  if(!ctx||!ctx->device||!ctx->command_buffer||!ctx->output) return;
  if(ctx->input_count<1||!ctx->inputs[0]) return;

  id<MTLDevice> dev=(__bridge id<MTLDevice>)ctx->device;
  id<MTLCommandBuffer> cb=(__bridge id<MTLCommandBuffer>)ctx->command_buffer;
  id<MTLTexture> inTex=(__bridge id<MTLTexture>)ctx->inputs[0];
  id<MTLTexture> outTex=(__bridge id<MTLTexture>)ctx->output;

  self->ensure(dev, outTex.pixelFormat);
  if(!self->pso) return;

  MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=outTex;
  rp.colorAttachments[0].loadAction=MTLLoadActionDontCare;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:self->pso];

  Params p{ self->amount, (float)ctx->time_seconds, { (float)ctx->width, (float)ctx->height } };
  [enc setFragmentBytes:&p length:sizeof(Params) atIndex:0];
  [enc setFragmentTexture:inTex atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];
}

static vj_plugin_instance_t* create(const vj_host_api_t* host){
  auto* inst=new Instance(); inst->host=host; return (vj_plugin_instance_t*)inst;
}
static void destroy(vj_plugin_instance_t* instance){ delete (Instance*)instance; }

static vj_plugin_descriptor_t g_desc = {
  .api_version = {VJ_PLUGIN_API_VERSION_MAJOR, VJ_PLUGIN_API_VERSION_MINOR},
  .plugin_id = "org.openvj.template.effect",
  .name = "Template Effect",
  .vendor = "OpenVJ Starter",
  .description = "Template effect plugin.",
  .kind = VJ_PLUGIN_EFFECT,
  .create = create,
  .destroy = destroy,
  .get_param_count = get_count,
  .get_param_desc  = get_desc,
  .set_param       = set_param,
  .get_param       = get_param,
  .render          = render,
};

extern "C" const vj_plugin_descriptor_t* vj_plugin_get_descriptor(void){ return &g_desc; }
