// Each WebGPU texture packs the configured cascades in 128³ tiles. Four
// cascades use a 2x2x1 grid; five through eight use 2x2x2. One/two use
// 1x1x1/2x1x1. Native drivers retain arrays.
#ifdef SDFGI_CASCADE_ATLAS
ivec3 sdfgi_cascade_offset(uint p_cascade, int p_size) {
	return ivec3(int(p_cascade & 1u), int((p_cascade >> 1u) & 1u), int(p_cascade >> 2u)) * p_size;
}
#define SDFGI_DECLARE_CASCADE_TEXTURES(m_name, m_binding)                             \
	layout(set = 0, binding = m_binding) uniform texture3D m_name;                    \
	vec4 m_name##_sample(uint m_idx, sampler m_samp, vec3 m_uv, float m_lod) {        \
		vec3 size = vec3(textureSize(sampler3D(m_name, m_samp), 0));                  \
		vec3 offset = vec3(sdfgi_cascade_offset(m_idx, 128));                         \
		/* Clamp before atlas mapping: filtering must not cross a cascade edge. */    \
		vec3 local = clamp(m_uv * 128.0, vec3(0.5), vec3(127.5));                     \
		return textureLod(sampler3D(m_name, m_samp), (offset + local) / size, m_lod); \
	}
#else
#define SDFGI_DECLARE_CASCADE_TEXTURES(m_name, m_binding)                      \
	layout(set = 0, binding = m_binding) uniform texture3D m_name[8];          \
	vec4 m_name##_sample(uint m_idx, sampler m_samp, vec3 m_uv, float m_lod) { \
		return textureLod(sampler3D(m_name[m_idx], m_samp), m_uv, m_lod);      \
	}
#endif
