\
#pragma once
/*
  VJ Plugin API (C ABI stable) — macOS + Metal
  ------------------------------------------------
  Objectif: ABI stable, plugins compilables indépendamment du core.

  Le core (host) charge la dylib, récupère vj_plugin_get_descriptor(),
  puis utilise les callbacks.

  Convention:
  - Le rendu est appelé depuis le render thread.
  - Aucune allocation lourde dans render() (cacher pipeline, buffers, etc.)
*/

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// --------------- Versioning ---------------

#define VJ_PLUGIN_API_VERSION_MAJOR 1
#define VJ_PLUGIN_API_VERSION_MINOR 0

typedef struct vj_version {
  uint16_t major;
  uint16_t minor;
} vj_version_t;

// --------------- Opaque Metal handles ---------------
// Pour garder l'ABI stable, on transporte des pointeurs opaques.
// Côté plugin (.mm), on les cast vers id<MTLDevice> etc.
typedef void* vj_mtl_device_t;
typedef void* vj_mtl_command_buffer_t;
typedef void* vj_mtl_texture_t;
typedef void* vj_mtl_render_pass_desc_t; // optionnel (pas utilisé dans v1)

// --------------- Paramètres ---------------

typedef enum vj_param_type {
  VJ_PARAM_FLOAT = 1,
  VJ_PARAM_INT   = 2,
  VJ_PARAM_BOOL  = 3,
  VJ_PARAM_ENUM  = 4,
  VJ_PARAM_COLOR = 5, // RGBA float 0..1
} vj_param_type_t;

typedef struct vj_color {
  float r, g, b, a;
} vj_color_t;

typedef struct vj_param_value {
  vj_param_type_t type;
  union {
    float    f;
    int32_t  i;
    uint8_t  b;
    vj_color_t color;
  };
  // Pour enum: valeur dans .i (index)
} vj_param_value_t;

typedef struct vj_param_desc {
  const char* id;      // unique key, ex: "amount"
  const char* label;   // UI label, ex: "Amount"
  vj_param_type_t type;

  // Pour float/int:
  float f_min;
  float f_max;
  float f_default;
  int32_t i_min;
  int32_t i_max;
  int32_t i_default;

  // Pour enum:
  const char** enum_labels;
  uint32_t enum_count;

  // Pour bool:
  uint8_t b_default;

  // Pour color:
  vj_color_t color_default;
} vj_param_desc_t;

// --------------- Contexte de rendu ---------------

typedef struct vj_render_context {
  // Metal
  vj_mtl_device_t device;
  vj_mtl_command_buffer_t command_buffer;

  // Textures (inputs/outputs)
  // Effect: inputs[0] -> output
  // Transition: inputs[0]=A, inputs[1]=B -> output
  // Generator: no inputs -> output
  vj_mtl_texture_t inputs[2];
  uint32_t input_count;

  vj_mtl_texture_t output;
  uint32_t width;
  uint32_t height;

  // Timing
  double time_seconds;     // temps absolu (monotonic)
  double delta_seconds;    // dt
  uint64_t frame_index;    // compteur de frames

  // (Optionnel v2: bpm, beat_phase, audio_rms, etc.)
} vj_render_context_t;

// --------------- Host services ---------------

typedef struct vj_host_api {
  vj_version_t api_version;

  // Logging (host side)
  void (*log_info)(const char* msg);
  void (*log_warn)(const char* msg);
  void (*log_error)(const char* msg);

  // Allocation/utility (optionnel v1)
  void* (*malloc)(size_t);
  void  (*free)(void*);

  // (Optionnel v2: cache pipeline, load assets, job system, midi/osc, etc.)
} vj_host_api_t;

// --------------- Plugin kinds ---------------

typedef enum vj_plugin_kind {
  VJ_PLUGIN_GENERATOR  = 1,
  VJ_PLUGIN_EFFECT     = 2,
  VJ_PLUGIN_TRANSITION = 3,
} vj_plugin_kind_t;

// --------------- Plugin descriptor & instance ---------------

typedef struct vj_plugin_descriptor vj_plugin_descriptor_t;
typedef struct vj_plugin_instance vj_plugin_instance_t;

typedef vj_plugin_instance_t* (*vj_create_fn)(const vj_host_api_t* host);
typedef void (*vj_destroy_fn)(vj_plugin_instance_t* instance);

typedef uint32_t (*vj_get_param_count_fn)(vj_plugin_instance_t* instance);
typedef const vj_param_desc_t* (*vj_get_param_desc_fn)(vj_plugin_instance_t* instance, uint32_t index);
typedef void (*vj_set_param_fn)(vj_plugin_instance_t* instance, const char* param_id, vj_param_value_t value);
typedef vj_param_value_t (*vj_get_param_fn)(vj_plugin_instance_t* instance, const char* param_id);

typedef void (*vj_render_fn)(vj_plugin_instance_t* instance, const vj_render_context_t* ctx);

struct vj_plugin_descriptor {
  vj_version_t api_version;      // doit matcher major
  const char* plugin_id;         // ex: "com.example.tranceglow"
  const char* name;              // ex: "Trance Glow"
  const char* vendor;            // ex: "OpenVJ"
  const char* description;       // text
  vj_plugin_kind_t kind;

  // lifecycle
  vj_create_fn  create;
  vj_destroy_fn destroy;

  // params
  vj_get_param_count_fn get_param_count;
  vj_get_param_desc_fn  get_param_desc;
  vj_set_param_fn       set_param;
  vj_get_param_fn       get_param;

  // render
  vj_render_fn render;
};

// Symbol exporté par la dylib plugin
// Le host charge ce symbole via dlsym("vj_plugin_get_descriptor")
const vj_plugin_descriptor_t* vj_plugin_get_descriptor(void);

#ifdef __cplusplus
} // extern "C"
#endif

#ifdef __cplusplus
// Empty base so C++ plugins can derive and upcast safely; C plugins can still
// provide their own definition in translation units.
struct vj_plugin_instance { };
#endif
