extends Node

signal render_step(ok: bool, detail: String)
const ITERATIONS := 64
var rd: RenderingDevice
var source_shader: RID
var source_texture: RID
var sampler: RID
var output_texture: RID
var source_uniforms: RID
var target_shader: RID
var target_pipeline: RID
var created := 0
var retired := 0
var dispatches := 0
var display: TextureRect
var display_texture: Texture2DRD

func run(native_readback: bool = false) -> bool:
	var setup: Array = await _step(_setup)
	if not setup[0]: return _fail(setup[1])
	display_texture = Texture2DRD.new()
	display_texture.texture_rd_rid = output_texture
	display = TextureRect.new()
	display.texture = display_texture
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.size = Vector2(512, 32)
	add_child(display)
	for index in ITERATIONS:
		var creation: Array = await _step(_create_target.bind(index % 2 == 1))
		if not creation[0]: return _fail(creation[1])
		if not await _settle(): return _fail("pipeline readiness timeout")
		var dispatch: Array = await _step(_dispatch.bind(index))
		if not dispatch[0]: return _fail(dispatch[1])
		await _frames(2)
		var retirement: Array = await _step(_retire_target)
		if not retirement[0]: return _fail(retirement[1])
		# RD defers destruction until a frame slot is reused. Advance well beyond
		# the three in-flight slots before creating the next target shader.
		await _frames(6)
	await _frames(4)
	if native_readback:
		var readback: Array = await _step(_native_readback)
		if not readback[0]: return _fail(readback[1])
	else:
		# The browser harness checks every green cell, then advances this gate.
		# No synchronous browser texture or buffer mapping is attempted.
		print("BROWSER_REBIND_READY")
		await get_parent().advance
	display.texture = null
	display_texture.texture_rd_rid = RID()
	display.queue_free()
	await _frames(2)
	var release: Array = await _step(_release)
	if not release[0]: return _fail(release[1])
	await _frames(6)
	var ok := created == ITERATIONS and retired == ITERATIONS and dispatches == ITERATIONS
	print("BROWSER_REBIND_RESULT ", JSON.stringify({"passed":ok,"created":created,"retired":retired,"dispatches":dispatches,"cells":ITERATIONS,"native_readback":native_readback}))
	return ok

func _fail(detail: String) -> bool:
	push_error("BROWSER_REBIND_FAIL " + detail)
	return false

func _step(operation: Callable) -> Array:
	RenderingServer.call_on_render_thread(operation)
	return await render_step

func _publish(ok: bool, detail: String = "") -> void:
	render_step.emit(ok, detail)

func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame
		RenderingServer.force_draw(false, 1.0 / 60.0)

func _settle() -> bool:
	var stable := 0
	var deadline := Time.get_ticks_msec() + 30000
	while stable < 2 and Time.get_ticks_msec() < deadline:
		await _frames(1)
		stable = stable + 1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 else 0
	return stable == 2

func _shader(filtered: bool) -> RID:
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_texture;
layout(set=0,binding=1,rgba8) restrict writeonly uniform image2D result_image;
layout(push_constant,std430) uniform Params { int index; float expected; int pad0; int pad1; } params;
void main(){ float actual = %s; imageStore(result_image,ivec2(params.index,0),abs(actual-params.expected)<0.00001?vec4(0,1,0,1):vec4(1,0,0,1)); }
""" % ("textureLod(source_texture,vec2(0.5),0.0).r" if filtered else "texelFetch(source_texture,ivec2(0),0).r")
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		return RID()
	return rd.shader_create_from_spirv(spirv, "browser_rebind_filter" if filtered else "browser_rebind_fetch")

func _setup() -> void:
	rd = RenderingServer.get_rendering_device()
	source_shader = _shader(false)
	var source_format := RDTextureFormat.new()
	source_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	source_format.width = 2
	source_format.height = 1
	source_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var image := Image.create(2, 1, false, Image.FORMAT_RGBAH)
	image.set_pixel(0, 0, Color(0.25, 0, 0, 1))
	image.set_pixel(1, 0, Color(0.75, 0, 0, 1))
	source_texture = rd.texture_create(source_format, RDTextureView.new(), [image.get_data()])
	var output_format := RDTextureFormat.new()
	output_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	output_format.width = ITERATIONS
	output_format.height = 1
	output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	output_texture = rd.texture_create(output_format, RDTextureView.new())
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(state)
	var input := RDUniform.new()
	input.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	input.binding = 0
	input.add_id(sampler)
	input.add_id(source_texture)
	var output := RDUniform.new()
	output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output.binding = 1
	output.add_id(output_texture)
	source_uniforms = rd.uniform_set_create([input, output], source_shader, 0)
	_publish.call_deferred(source_uniforms.is_valid(), "source uniform creation")

func _create_target(filtered: bool) -> void:
	target_shader = _shader(filtered)
	target_pipeline = rd.compute_pipeline_create(target_shader)
	created += 1
	_publish.call_deferred(target_shader.is_valid() and target_pipeline.is_valid(), "target creation")

func _dispatch(index: int) -> void:
	if not rd.uniform_set_is_valid(source_uniforms):
		_publish.call_deferred(false, "source uniform invalidated with target shader")
		return
	var constants := PackedByteArray()
	constants.resize(16)
	constants.encode_s32(0, index)
	constants.encode_float(4, 0.5 if index % 2 == 1 else 0.25)
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, target_pipeline)
	rd.compute_list_bind_uniform_set(commands, source_uniforms, 0)
	rd.compute_list_set_push_constant(commands, constants, 16)
	rd.compute_list_dispatch(commands, 1, 1, 1)
	rd.compute_list_end()
	dispatches += 1
	_publish.call_deferred(true)

func _retire_target() -> void:
	# Pipeline dependencies are freed with their shader; the source uniform set
	# deliberately outlives every target and its per-set bind group layouts.
	rd.free_rid(target_shader)
	target_shader = RID()
	target_pipeline = RID()
	retired += 1
	_publish.call_deferred(rd.uniform_set_is_valid(source_uniforms), "source uniform lifetime")

func _native_readback() -> void:
	var data := rd.texture_get_data(output_texture, 0)
	var ok := data.size() == ITERATIONS * 4
	for index in ITERATIONS:
		ok = ok and data[index * 4] == 0 and data[index * 4 + 1] == 255 and data[index * 4 + 2] == 0 and data[index * 4 + 3] == 255
	_publish.call_deferred(ok, "native 64-cell GPU oracle")

func _release() -> void:
	for resource: RID in [source_uniforms, source_shader, sampler, source_texture, output_texture]:
		rd.free_rid(resource)
	_publish.call_deferred(true)
