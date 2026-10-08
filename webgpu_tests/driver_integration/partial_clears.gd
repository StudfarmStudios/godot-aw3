extends RefCounted

# Exercise real render-area clears, including formats for which a blend-constant
# clear cannot work. Every read verifies the complete attachment, not just the tile.
const TILE := Rect2i(2, 1, 3, 3)
const SECOND := Rect2i(4, 3, 2, 1)

func _texture(h, format: int, depth: bool = false, samples: int = RenderingDevice.TEXTURE_SAMPLES_1) -> RID:
	var tf: RDTextureFormat = h._format(format, 7, 5)
	tf.samples = samples
	tf.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | (RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT if depth else RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT))
	return h._own(h.rd.texture_create(tf, RDTextureView.new()))

func _half_pixel(bytes: PackedByteArray, offset: int, tile: bool) -> void:
	for channel in 4:
		bytes.encode_u16(offset + channel * 2, [0xc000, 0x3800, 0x4200, 0x4400][channel] if tile else 0x3c00)

func _multiple_targets(h) -> void:
	var formats := [RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.DATA_FORMAT_R32_UINT, RenderingDevice.DATA_FORMAT_R32_SINT]
	var textures: Array[RID] = []
	for format in formats:
		textures.append(_texture(h, format))
	textures.append(_texture(h, RenderingDevice.DATA_FORMAT_D32_SFLOAT, true))
	var framebuffer: RID = h._own(h.rd.framebuffer_create(textures))
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE], 0.75)
	h.rd.draw_list_end()
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL,
		[Color.BLUE, Color(-2, 0.5, 3, 4), Color(-7.25, 0, 0, 0), Color(1025, 0, 0, 0), Color(-17, 0, 0, 0)], 0.25, 0, TILE)
	h.rd.draw_list_end()
	# A second ring slot and a sparse clear mask: other targets/depth must survive.
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0 | RenderingDevice.DRAW_CLEAR_COLOR_2,
		[Color.RED, Color.BLACK, Color(0.5, 0, 0, 0)], 0.0, 0, SECOND)
	h.rd.draw_list_end()
	for target in textures.size():
		var expected := PackedByteArray()
		var pixel_bytes := 8 if target == 1 else 4
		expected.resize(35 * pixel_bytes)
		for y in 5:
			for x in 7:
				var tile := TILE.has_point(Vector2i(x, y))
				var second := SECOND.has_point(Vector2i(x, y))
				var offset := (y * 7 + x) * pixel_bytes
				match target:
					0: expected.encode_u32(offset, 0xff0000ff if second else (0xffff0000 if tile else 0xffffffff))
					1: _half_pixel(expected, offset, tile)
					2: expected.encode_float(offset, 0.5 if second else (-7.25 if tile else 1.0))
					3: expected.encode_u32(offset, 1025 if tile else 1)
					4: expected.encode_s32(offset, -17 if tile else 1)
					5: expected.encode_float(offset, 0.25 if tile else 0.75)
		h._read("partial MRT target %d" % target, textures[target], 0, expected)

func _depth_atlas(h) -> void:
	var depth := _texture(h, RenderingDevice.DATA_FORMAT_D32_SFLOAT, true)
	var framebuffer: RID = h._own(h.rd.framebuffer_create([depth]))
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_DEPTH, [], 0.75)
	h.rd.draw_list_end()
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_DEPTH, [], 0.25, 0, TILE)
	h.rd.draw_list_end()
	var expected := PackedByteArray()
	expected.resize(35 * 4)
	for y in 5:
		for x in 7:
			expected.encode_float((y * 7 + x) * 4, 0.25 if TILE.has_point(Vector2i(x, y)) else 0.75)
	h._read("partial depth atlas fast path", depth, 0, expected)

func _msaa(h) -> void:
	var source := _texture(h, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, false, RenderingDevice.TEXTURE_SAMPLES_4)
	var dest := _texture(h, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var framebuffer: RID = h._own(h.rd.framebuffer_create([source]))
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.WHITE])
	h.rd.draw_list_end()
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color(-2, 0.5, 3, 4)], 1.0, 0, TILE)
	h.rd.draw_list_end()
	h.rd.texture_resolve_multisample(source, dest)
	var expected := PackedByteArray()
	expected.resize(35 * 8)
	for y in 5:
		for x in 7:
			_half_pixel(expected, (y * 7 + x) * 8, TILE.has_point(Vector2i(x, y)))
	h._read("partial HDR MSAA clear", dest, 0, expected)

func _probe_pipeline(h, framebuffer: RID, stencil: bool) -> RID:
	var source := RDShaderSource.new()
	source.source_vertex = """#version 450
void main() { vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
gl_Position = vec4(p * 2.0 - 1.0, 0.5, 1.0); }
"""
	source.source_fragment = """#version 450
layout(location=0) out vec4 color;
void main() { color = vec4(1.0); }
"""
	var spirv = h.rd.shader_compile_spirv_from_source(source, false)
	var shader: RID = h._own(h.rd.shader_create_from_spirv(spirv))
	var state := RDPipelineDepthStencilState.new()
	if stencil:
		state.enable_stencil = true
		state.front_op_compare = RenderingDevice.COMPARE_OP_EQUAL
		state.back_op_compare = RenderingDevice.COMPARE_OP_EQUAL
		state.front_op_compare_mask = 255
		state.back_op_compare_mask = 255
		state.front_op_reference = 3
		state.back_op_reference = 3
	else:
		state.enable_depth_test = true
		state.depth_compare_operator = RenderingDevice.COMPARE_OP_LESS
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new()]
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	return h._own(h.rd.render_pipeline_create(shader, h.rd.framebuffer_get_format(framebuffer), RenderingDevice.INVALID_ID,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), state, blend))

func _stencil(h) -> void:
	var color := _texture(h, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	var depth := _texture(h, RenderingDevice.DATA_FORMAT_D32_SFLOAT_S8_UINT, true)
	var framebuffer: RID = h._own(h.rd.framebuffer_create([color, depth]))
	var stencil_probe := _probe_pipeline(h, framebuffer, true)
	var depth_probe := _probe_pipeline(h, framebuffer, false)
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.BLACK], 0.75, 3)
	h.rd.draw_list_end()
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.BLUE], 0.25, 7, TILE)
	h.rd.draw_list_end()
	for test in 2:
		# First probe stencil; second probe depth while preserving stencil/depth.
		var commands = h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_DEFAULT_ALL if test == 0 else RenderingDevice.DRAW_CLEAR_COLOR_0, [Color.BLACK])
		h.rd.draw_list_bind_render_pipeline(commands, stencil_probe if test == 0 else depth_probe)
		h.rd.draw_list_draw(commands, false, 1, 3)
		h.rd.draw_list_end()
		var expected := PackedByteArray()
		expected.resize(35 * 4)
		for y in 5:
			for x in 7:
				var inside := 0xffff0000 if test == 0 else 0xff000000
				expected.encode_u32((y * 7 + x) * 4, inside if TILE.has_point(Vector2i(x, y)) else 0xffffffff)
		h._read("partial stencil attachment %s probe" % ("stencil" if test == 0 else "depth"), color, 0, expected)

func _ring_wrap(h) -> void:
	var texture := _texture(h, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	var framebuffer: RID = h._own(h.rd.framebuffer_create([texture]))
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.BLACK])
	h.rd.draw_list_end()
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0, [Color.RED], 1.0, 0, Rect2(1, 1, 1, 1))
	h.rd.draw_list_end()
	# The shared ring holds 2048 slots. Preserve a pre-wrap sentinel while
	# changing another tile through more slots than fit in one submission.
	for i in 2100:
		h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0, [Color.BLUE if i % 2 else Color.GREEN], 1.0, 0, Rect2(2, 1, 1, 1))
		h.rd.draw_list_end()
	h.rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0, [Color.MAGENTA], 1.0, 0, Rect2(3, 1, 1, 1))
	h.rd.draw_list_end()
	var expected := PackedByteArray()
	expected.resize(35 * 4)
	for pixel in 35:
		expected.encode_u32(pixel * 4, 0xff000000)
	expected.encode_u32(8 * 4, 0xff0000ff)
	expected.encode_u32(9 * 4, 0xffff0000)
	expected.encode_u32(10 * 4, 0xffff00ff)
	h._read("partial clear upload ring wrap", texture, 0, expected)

func run(h) -> void:
	_multiple_targets(h)
	_depth_atlas(h)
	_msaa(h)
	_stencil(h)
	_ring_wrap(h)
