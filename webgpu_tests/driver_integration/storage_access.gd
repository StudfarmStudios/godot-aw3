extends RefCounted

# Read/write eligibility depends on the physical format, not only the WGSL
# language feature. Unused HDR/3D/array images also check pruned-declaration layouts.
func run(host: Node) -> void:
	var rd: RenderingDevice = host.rd
	for entry: Array in [
		["rg32f", RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, 2, false],
		["rg16f", RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, 2, true],
		["rgba32f", RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, 4, false],
		["rgba16f", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, 4, true],
	]:
		var texture: RID = host._own(rd.texture_create(host._format(entry[1], 5, 3), RDTextureView.new()))
		var unused: RID = host._own(rd.texture_create(host._format(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, 5, 3), RDTextureView.new()))
		var unused_3d: RID = host._own(rd.texture_create(host._format(RenderingDevice.DATA_FORMAT_R32_UINT, 5, 3, RenderingDevice.TEXTURE_TYPE_3D, 2), RDTextureView.new()))
		var unused_array: RID = host._own(rd.texture_create(host._format(RenderingDevice.DATA_FORMAT_R16_SFLOAT, 5, 3, RenderingDevice.TEXTURE_TYPE_2D_ARRAY, 2), RDTextureView.new()))
		var unused_uint: RID = host._own(rd.texture_create(host._format(RenderingDevice.DATA_FORMAT_R32_UINT, 5, 3), RDTextureView.new()))
		var unused_sint: RID = host._own(rd.texture_create(host._format(RenderingDevice.DATA_FORMAT_R32_SINT, 5, 3, RenderingDevice.TEXTURE_TYPE_3D, 2), RDTextureView.new()))
		var unused_uint_array: RID = host._own(rd.texture_create(host._format(RenderingDevice.DATA_FORMAT_R32_UINT, 5, 3, RenderingDevice.TEXTURE_TYPE_2D_ARRAY, 2), RDTextureView.new()))
		var sampler: RID = host._own(rd.sampler_create(RDSamplerState.new()))
		for write_only: bool in [true, false, false]:
			var source := RDShaderSource.new()
			source.source_compute = """#version 450
layout(local_size_x=1, local_size_y=1, local_size_z=1) in;
layout(%s, set=0, binding=0) uniform %simage2D values;
layout(rgba16f, set=0, binding=1) writeonly uniform image2D unused_hdr;
layout(r32ui, set=0, binding=2) readonly uniform uimage3D unused_volume;
layout(r16f, set=0, binding=3) readonly uniform image2DArray unused_array;
layout(set=0, binding=4) uniform utexture2D unused_unsigned_texture;
layout(set=0, binding=5) uniform itexture3D unused_signed_texture;
layout(set=0, binding=6) uniform usampler2DArray unused_combined_sampler;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    imageStore(values, p, %s);
}
""" % [entry[0], "writeonly " if write_only else "", "vec4(3.0)" if write_only else "imageLoad(values, p) + vec4(2.0)"]
			var spirv := rd.shader_compile_spirv_from_source(source, false)
			if not spirv.compile_error_compute.is_empty():
				push_error(spirv.compile_error_compute)
			var shader: RID = host._own(rd.shader_create_from_spirv(spirv))
			var pipeline: RID = host._own(rd.compute_pipeline_create(shader))
			var uniforms: Array[RDUniform] = []
			var textures := [texture, unused, unused_3d, unused_array, unused_uint, unused_sint, unused_uint_array]
			for index in textures.size():
				var uniform := RDUniform.new()
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if index < 4 else RenderingDevice.UNIFORM_TYPE_TEXTURE
				if index == 6:
					uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
					uniform.add_id(sampler)
				uniform.binding = index
				uniform.add_id(textures[index])
				uniforms.append(uniform)
			var set: RID = host._own(rd.uniform_set_create(uniforms, shader, 0))
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, set, 0)
			rd.compute_list_dispatch(list, 5, 3, 1)
			rd.compute_list_end()
		var expected := PackedByteArray()
		var component_size := 2 if entry[3] else 4
		expected.resize(15 * entry[2] * component_size)
		for component in 15 * entry[2]:
			if entry[3]:
				expected.encode_half(component * component_size, 7.0)
			else:
				expected.encode_float(component * component_size, 7.0)
		host._read("storage access " + entry[0], texture, 0, expected)
