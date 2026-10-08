extends SceneTree
var rd: RenderingDevice
var owned: Array[RID] = []
var sampler: RID
var passed := 0
var failed := 0
var output_directory := ""

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--filter-output="): output_directory = argument.trim_prefix("--filter-output=")
	call_deferred("_run")

func _own(resource: RID) -> RID:
	if resource.is_valid(): owned.append(resource)
	return resource

func _check(ok: bool,label: String,detail: Variant = "") -> void:
	passed += int(ok)
	failed += int(not ok)
	print("SAMPLED_FILTERING %s %s %s" % ["PASS" if ok else "FAIL",label,detail])

func _clear() -> void:
	for index in range(owned.size()-1,-1,-1): rd.free_rid(owned[index])
	owned.clear()

func _texture(filtered: bool) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if filtered else RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.width = 2
	format.height = 1
	# Storage use prevents the driver's unrelated float32 upload downgrade.
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var data := PackedFloat32Array([0.0,1.0]).to_byte_array()
	if filtered:
		var image := Image.create(2,1,false,Image.FORMAT_RGBAH)
		image.set_pixel(0,0,Color(0,0,0,1))
		image.set_pixel(1,0,Color(1,1,1,1))
		data = image.get_data()
	return _own(rd.texture_create(format,RDTextureView.new(),[data]))

func _texture_uniforms(texture: RID,separate: bool) -> Array[RDUniform]:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE if separate else RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	if not separate: uniform.add_id(sampler)
	uniform.add_id(texture)
	var result: Array[RDUniform] = [uniform]
	if separate:
		var separate_sampler := RDUniform.new()
		separate_sampler.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
		separate_sampler.binding = 2
		separate_sampler.add_id(sampler)
		result.append(separate_sampler)
	return result

func _compute_case(label: String) -> void:
	var filtered := label.begins_with("filter_")
	var separate := label == "fetch_separate"
	var pushed := label == "fetch_push"
	var pruned := label.ends_with("pruned")
	var future := label == "filter_future"
	var source_set := 3 if pushed else 0
	var declaration := "layout(set=%d,binding=0) uniform sampler2D source_texture;\n" % source_set
	var source_expression := "source_texture"
	if separate:
		declaration = "layout(set=0,binding=0) uniform texture2D source_texture; layout(set=0,binding=2) uniform sampler source_sampler;\n"
		source_expression = "sampler2D(source_texture,source_sampler)"
	var exact := "texelFetch(%s,ivec2(index,0),0).r" % source_expression
	var interpolated := "textureLod(%s,vec2(0.5,0.5),0.0).r" % source_expression
	var helpers := ""
	var operation: String = interpolated if filtered else exact
	if label.ends_with("helper") or label.ends_with("nested"):
		helpers = "float inner(sampler2D value,int x){return %s;}\n" % ("textureLod(value,vec2(0.5),0.0).r" if filtered else "texelFetch(value,ivec2(x,0),0).r")
		operation = "inner(source_texture,index)"
		if label.ends_with("nested"):
			helpers += "float outer(sampler2D value,int x){return inner(value,x);}\n"
			operation = "outer(source_texture,index)"
	if future: operation = "COUNT>1 ? %s : %s" % [interpolated,exact]
	if label == "fetch_dimensions": operation = "float(textureSize(source_texture,0).x+textureQueryLevels(source_texture))"
	if pruned: operation = "COUNT>1 ? %s : 0.25" % operation
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(constant_id=0) const int COUNT=1;
%s
layout(set=0,binding=1,std430) restrict writeonly buffer Output { float values[]; } output_data;
%s
%s
void main(){int index=int(gl_GlobalInvocationID.x)%%2; %s float proof[COUNT];proof[COUNT-1]=0.0;output_data.values[gl_GlobalInvocationID.x]=(%s)+proof[COUNT-1];}
""" % [declaration,"layout(push_constant,std430) uniform Params{int offset;}params;" if pushed else "",helpers,"index=(index+params.offset)%2;" if pushed else "",operation]
	var spirv := rd.shader_compile_spirv_from_source(source,false)
	if not spirv.compile_error_compute.is_empty(): push_error(spirv.compile_error_compute); return
	var file := FileAccess.open(output_directory.path_join(label+".spv"),FileAccess.WRITE)
	file.store_buffer(spirv.bytecode_compute)
	var shader := _own(rd.shader_create_from_spirv(spirv,label))
	var texture := _texture(filtered)
	var initial_data := rd.texture_get_data(texture,0)
	var output := _own(rd.storage_buffer_create(16))
	var buffer := RDUniform.new()
	buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer.binding = 1
	buffer.add_id(output)
	var uniforms := _texture_uniforms(texture,separate)
	var bindings: Array[RID] = []
	if pushed:
		bindings = [_own(rd.uniform_set_create([buffer],shader,0)),_own(rd.uniform_set_create(uniforms,shader,3))]
	else:
		uniforms.append(buffer)
		bindings = [_own(rd.uniform_set_create(uniforms,shader,0))]
	var base := _own(rd.compute_pipeline_create(shader))
	var constant := RDPipelineSpecializationConstant.new()
	constant.constant_id = 0
	constant.value = 2
	var specialized := _own(rd.compute_pipeline_create(shader,[constant]))
	_check(base.is_valid() and specialized.is_valid(),label+"_pipelines")
	for phase in 2:
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands,base if phase==0 else specialized)
		rd.compute_list_bind_uniform_set(commands,bindings[0],0)
		if pushed:
			rd.compute_list_bind_uniform_set(commands,bindings[1],3)
			rd.compute_list_set_push_constant(commands,PackedInt32Array([1]).to_byte_array(),4)
		rd.compute_list_dispatch(commands,4,1,1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var values := rd.buffer_get_data(output).to_float32_array()
		var ok := values.size()==4
		for index in values.size():
			var expected := 0.25 if pruned and phase==0 else (0.5 if filtered and not(future and phase==0) else float((index+int(pushed))%2))
			if label == "fetch_dimensions": expected = 3.0
			ok = ok and is_finite(values[index]) and absf(values[index]-expected)<0.00001
		_check(ok,label+"_phase"+str(phase),values)
	_check(rd.texture_get_data(texture,0)==initial_data,label+"_source_unchanged")
	_clear()

func _graphics_case(filter_vertex: bool) -> void:
	var label := "stage_union_vertex_filter" if filter_vertex else "stage_union_fragment_filter"
	var source := RDShaderSource.new()
	var declaration := "layout(set=0,binding=0) uniform sampler2D source_texture;\n"
	var fetch := "texelFetch(source_texture,ivec2(0),0).r"
	var filtered := "textureLod(source_texture,vec2(0.5),0.0).r"
	source.source_vertex = "#version 450\n" + declaration + "layout(location=0) out float value; void main(){vec2 p=vec2((gl_VertexIndex<<1)&2,gl_VertexIndex&2);gl_Position=vec4(p*2.0-1.0,0.0,1.0);value=" + (filtered if filter_vertex else fetch) + ";}"
	source.source_fragment = "#version 450\n" + declaration + "layout(location=0) in float value;layout(location=0) out vec4 color; void main(){color=vec4(vec3(value+" + (fetch if filter_vertex else filtered) + "),1.0);}"
	var spirv := rd.shader_compile_spirv_from_source(source,false)
	if not spirv.compile_error_vertex.is_empty() or not spirv.compile_error_fragment.is_empty(): push_error(spirv.compile_error_vertex+spirv.compile_error_fragment); return
	var shader := _own(rd.shader_create_from_spirv(spirv,label))
	var texture := _texture(true)
	var uniforms := _own(rd.uniform_set_create(_texture_uniforms(texture,false),shader,0))
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = 4
	format.height = 4
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var target := _own(rd.texture_create(format,RDTextureView.new()))
	var framebuffer := _own(rd.framebuffer_create([target]))
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new()]
	var pipeline := _own(rd.render_pipeline_create(shader,rd.framebuffer_get_format(framebuffer),-1,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,raster,RDPipelineMultisampleState.new(),RDPipelineDepthStencilState.new(),blend))
	_check(pipeline.is_valid(),label+"_pipeline")
	var commands := rd.draw_list_begin(framebuffer,RenderingDevice.DRAW_CLEAR_ALL,[Color.BLACK])
	rd.draw_list_bind_render_pipeline(commands,pipeline)
	rd.draw_list_bind_uniform_set(commands,uniforms,0)
	rd.draw_list_draw(commands,false,1,3)
	rd.draw_list_end()
	rd.submit()
	rd.sync()
	var pixels := rd.texture_get_data(target,0)
	var ok := pixels.size()==64
	for index in pixels.size(): ok = ok and (pixels[index]==255 if index%4==3 else absi(pixels[index]-128)<=1)
	_check(ok,label+"_filtered_pixels",pixels.slice(0,16).hex_encode())
	_clear()

func _reuse_case(filtered_texture: bool, create_from_filter: bool) -> void:
	var label := "reuse_%s_from_%s" % ["rgba16f" if filtered_texture else "r32f", "filter" if create_from_filter else "fetch"]
	var texture := _texture(filtered_texture)
	var initial_data := rd.texture_get_data(texture,0)
	var output := _own(rd.storage_buffer_create(16))
	var buffer := RDUniform.new()
	buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer.binding = 1
	buffer.add_id(output)
	var shaders: Array[RID] = []
	var pipelines: Array[RID] = []
	for filtered in [false,true]:
		var source := RDShaderSource.new()
		source.source_compute = """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_texture;
layout(set=0,binding=1,std430) restrict writeonly buffer Output{float values[];}output_data;
void main(){int index=int(gl_GlobalInvocationID.x)%%2;output_data.values[gl_GlobalInvocationID.x]=%s;}
""" % ("textureLod(source_texture,vec2(0.5),0.0).r" if filtered else "texelFetch(source_texture,ivec2(index,0),0).r")
		var spirv := rd.shader_compile_spirv_from_source(source,false)
		if not spirv.compile_error_compute.is_empty(): push_error(spirv.compile_error_compute); return
		var shader := _own(rd.shader_create_from_spirv(spirv,label+str(filtered)))
		shaders.append(shader)
		pipelines.append(_own(rd.compute_pipeline_create(shader)))
	var uniforms := _texture_uniforms(texture,false)
	uniforms.append(buffer)
	var source_index := int(create_from_filter)
	var bindings := _own(rd.uniform_set_create(uniforms,shaders[source_index],0))
	_check(pipelines[0].is_valid() and pipelines[1].is_valid(),label+"_pipelines")
	for phase in 3:
		var target := source_index if phase!=1 else 1-source_index
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands,pipelines[target])
		rd.compute_list_bind_uniform_set(commands,bindings,0)
		rd.compute_list_dispatch(commands,4,1,1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var values := rd.buffer_get_data(output).to_float32_array()
		var ok := values.size()==4
		var supports_linear := rd.sampler_is_format_supported_for_filter(RenderingDevice.DATA_FORMAT_R32_SFLOAT,RenderingDevice.SAMPLER_FILTER_LINEAR)
		for index in values.size():
			var expected := float(index%2) if target==0 else (0.5 if filtered_texture or supports_linear else 0.0)
			# Actual filtered R32F without its optional feature retains the old
			# blank fallback. This tests compatible reuse, not filtering fidelity.
			ok = ok and is_finite(values[index]) and absf(values[index]-expected)<0.00001
		_check(ok,label+"_phase"+str(phase),values)
	_check(rd.texture_get_data(texture,0)==initial_data,label+"_source_unchanged")
	_clear()

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(state)
	for label in ["fetch_direct","fetch_dimensions","fetch_helper","fetch_nested","fetch_separate","fetch_typed","fetch_pruned","fetch_push","filter_direct","filter_helper","filter_future","filter_pruned"]: _compute_case(label)
	_graphics_case(false)
	_graphics_case(true)
	for filtered_texture in [false,true]:
		for create_from_filter in [false,true]: _reuse_case(filtered_texture,create_from_filter)
	rd.free_rid(sampler)
	rd.free()
	print("SAMPLED_FILTERING COMPLETE passed=%d failed=%d" % [passed,failed])
	quit(0 if failed==0 and passed==72 else 1)
