extends SceneTree

var rd: RenderingDevice
var owned: Array[RID] = []
var case_name := "fragment_read"
var expect_rejection := false
var passed := 0
var failed := 0

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--graphics-case="): case_name = argument.trim_prefix("--graphics-case=")
		if argument == "--expect-rejection": expect_rejection = true
	call_deferred("_run")

func _own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	return rid

func _check(success: bool, label: String, detail: Variant = "") -> void:
	passed += int(success)
	failed += int(not success)
	print("SPECIALIZATION_GRAPHICS %s %s %s" % ["PASS" if success else "FAIL", label, detail])

func _finish() -> void:
	for index in range(owned.size() - 1, -1, -1): rd.free_rid(owned[index])
	rd.free()
	print("SPECIALIZATION_GRAPHICS COMPLETE passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	var is_vertex := case_name == "vertex_read"
	var is_rw := case_name == "fragment_rw" or case_name == "fragment_rg_rw"
	var unused := case_name == "unused_rg_rw"
	var rg := case_name == "fragment_rg_rw" or unused
	var declaration := "layout(%s,set=0,binding=0) uniform %simage2D source_image;\n" % ["rg32f" if rg else "r32f", "" if is_rw or unused else "readonly "]
	var constants := "layout(constant_id=0) const int COUNT=1; layout(constant_id=1) const bool ACTIVE=false;\n"
	var proof := "float proof[COUNT]; proof[COUNT-1]=0.25; float value=proof[COUNT-1];"
	var operation := "if (ACTIVE) { value += imageLoad(source_image, %s).r; %s }" % ["ivec2(0)" if is_vertex else "ivec2(gl_FragCoord.xy)", "imageStore(source_image, ivec2(gl_FragCoord.xy), vec4(value));" if is_rw else ""]
	var source := RDShaderSource.new()
	source.source_vertex = "#version 450\nlayout(location=0) out float vertex_value;\n"
	if is_vertex: source.source_vertex += declaration + constants
	source.source_vertex += "void main(){vec2 p=vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2); gl_Position=vec4(p*2.0-1.0,0.0,1.0);"
	source.source_vertex += proof + operation + "vertex_value=value;" if is_vertex else "vertex_value=0.5;"
	source.source_vertex += "}"
	source.source_fragment = "#version 450\nlayout(location=0) in float vertex_value; layout(location=0) out vec4 color;\n"
	if not is_vertex: source.source_fragment += declaration + ("" if unused else constants)
	source.source_fragment += "void main(){"
	source.source_fragment += "float value=vertex_value;" if is_vertex or unused else proof + operation
	source.source_fragment += "color=vec4(value,value,value,1.0);}"
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_vertex.is_empty() or not spirv.compile_error_fragment.is_empty():
		push_error(spirv.compile_error_vertex + spirv.compile_error_fragment)
		quit(2)
		return
	var shader := _own(rd.shader_create_from_spirv(spirv, "specialization_" + case_name))
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.width = 4
	tf.height = 4
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var target := _own(rd.texture_create(tf, RDTextureView.new()))
	var framebuffer := _own(rd.framebuffer_create([target]))
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new()]
	var specs: Array[RDPipelineSpecializationConstant] = []
	if not unused:
		var count := RDPipelineSpecializationConstant.new()
		count.constant_id = 0
		count.value = 3
		var active := RDPipelineSpecializationConstant.new()
		active.constant_id = 1
		active.value = true
		specs = [count, active]
	var pipeline := _own(rd.render_pipeline_create(shader, rd.framebuffer_get_format(framebuffer), -1, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend, 0, 0, specs))
	if expect_rejection:
		_check(not pipeline.is_valid(), "unsupported_graphics_split_rejected", case_name)
		_finish()
		return
	_check(pipeline.is_valid(), "graphics_pipeline_valid", case_name)
	if not pipeline.is_valid():
		_finish()
		return
	tf.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT if rg else RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var values := PackedFloat32Array()
	values.resize(16 * (2 if rg else 1))
	values.fill(0.25)
	var input_texture := _own(rd.texture_create(tf, RDTextureView.new(), [values.to_byte_array()]))
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(input_texture)
	var uniforms := _own(rd.uniform_set_create([uniform], shader, 0))
	var commands := rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.BLACK])
	rd.draw_list_bind_render_pipeline(commands, pipeline)
	rd.draw_list_bind_uniform_set(commands, uniforms, 0)
	rd.draw_list_draw(commands, false, 1, 3)
	rd.draw_list_end()
	rd.submit()
	rd.sync()
	var pixels := rd.texture_get_data(target, 0)
	var valid := pixels.size() == 64
	for index in pixels.size():
		valid = valid and (pixels[index] == 255 if index % 4 == 3 else absi(pixels[index] - 128) <= 1)
	_check(valid, "draw_pixels", pixels.slice(0, 16).hex_encode())
	var actual := rd.texture_get_data(input_texture, 0).to_float32_array()
	valid = actual.size() == values.size()
	for value in actual: valid = valid and value == (0.5 if is_rw else 0.25)
	_check(valid, "source_pixels", actual.slice(0, 4))
	_finish()
