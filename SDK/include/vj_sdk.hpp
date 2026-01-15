\
#pragma once
/*
  Petit wrapper C++ (header-only) pour rendre les plugins plus confortables.

  Note: tu peux ignorer ce fichier et coder en C pur si tu veux.
*/
#include "vj_plugin_api.h"
#include <string.h>

namespace vj {

inline vj_param_value_t make_float(float v) {
  vj_param_value_t out{};
  out.type = VJ_PARAM_FLOAT;
  out.f = v;
  return out;
}

inline vj_param_value_t make_int(int32_t v) {
  vj_param_value_t out{};
  out.type = VJ_PARAM_INT;
  out.i = v;
  return out;
}

inline vj_param_value_t make_bool(bool v) {
  vj_param_value_t out{};
  out.type = VJ_PARAM_BOOL;
  out.b = v ? 1 : 0;
  return out;
}

inline vj_param_value_t make_color(float r,float g,float b,float a=1.f) {
  vj_param_value_t out{};
  out.type = VJ_PARAM_COLOR;
  out.color = vj_color_t{r,g,b,a};
  return out;
}

inline bool id_eq(const char* a, const char* b) {
  return a && b && ::strcmp(a,b) == 0;
}

} // namespace vj
