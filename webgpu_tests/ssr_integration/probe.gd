extends CompositorEffect
var observed_frames := 0
var capture_path := ""
var debug_buffers := false
var released := false
var capture_shader: RID
var capture_pipeline: RID
var capture_sampler: RID
func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
func _render_callback(_type: int, data: RenderData) -> void:
	if debug_buffers and not capture_shader.is_valid():
		var rd := RenderingServer.get_rendering_device()
		var source := RDShaderSource.new()
		source.source_compute = """#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_texture;
layout(set=0,binding=1,std430) restrict writeonly buffer Output { vec4 values[]; };
void main(){ ivec2 p=ivec2(gl_GlobalInvocationID.xy); ivec2 size=textureSize(source_texture,0); if(any(greaterThanEqual(p,size))) return; values[p.y*size.x+p.x]=texelFetch(source_texture,p,0); }
"""
		capture_shader = rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
		capture_pipeline = rd.compute_pipeline_create(capture_shader)
		capture_sampler = rd.sampler_create(RDSamplerState.new())
	if not capture_path.is_empty():
		var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
		var rd := RenderingServer.get_rendering_device()
		var captures: Array = []
		for pair: Array in [["rb_ssr", "hiz"], ["rb_ssr", "normal_roughness"], ["rb_ssr", "ssr"], ["rb_ssr", "mip_level"], ["rb_ssr", "final"], ["rb_sslf", "last_frame"], ["forward_clustered", "normal_roughness"]]:
			if not buffers.has_texture(pair[0], pair[1]): continue
			var texture := buffers.get_texture(pair[0], pair[1])
			var format := rd.texture_get_format(texture)
			for mip in format.mipmaps:
				var width: int = maxi(1, format.width >> mip)
				var height: int = maxi(1, format.height >> mip)
				var slice := buffers.get_texture_slice(pair[0], pair[1], 0, mip, 1, 1)
				var output := rd.storage_buffer_create(width * height * 16)
				var u_source := RDUniform.new()
				u_source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u_source.binding = 0
				u_source.add_id(capture_sampler)
				u_source.add_id(slice)
				var u_output := RDUniform.new()
				u_output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				u_output.binding = 1
				u_output.add_id(output)
				var uniforms := rd.uniform_set_create([u_source,u_output],capture_shader,0)
				var compute := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute,capture_pipeline)
				rd.compute_list_bind_uniform_set(compute,uniforms,0)
				rd.compute_list_dispatch(compute,ceili(width/8.0),ceili(height/8.0),1)
				rd.compute_list_end()
				var bytes := rd.buffer_get_data(output)
				var name: String = pair[0] + "_" + pair[1] + "_mip" + str(mip)
				var file := FileAccess.open(capture_path + "-" + name + ".bin", FileAccess.WRITE)
				file.store_buffer(bytes)
				captures.append({"name":name,"width":width,"height":height,"format":format.format,"bytes":bytes.size()})
				rd.free_rid(uniforms)
				rd.free_rid(output)
		var file := FileAccess.open(capture_path + "-buffers.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(captures, "  "))
		capture_path = ""
	_publish.call_deferred()
func _publish() -> void:
	observed_frames += 1

func release_gpu() -> void:
	debug_buffers = false
	var rd := RenderingServer.get_rendering_device()
	if capture_shader.is_valid():
		rd.free_rid(capture_shader)
		capture_shader = RID()
	if capture_sampler.is_valid():
		rd.free_rid(capture_sampler)
		capture_sampler = RID()

	_publish_release.call_deferred()

func _publish_release() -> void:
	released = true
