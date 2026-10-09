extends Node

const Probe = preload("res://probe.gd")
var viewport: SubViewport
var camera: Camera3D
var probe: CompositorEffect
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID
var readback: PackedFloat32Array
var read_complete := false
var passed := 0
var failed := 0

func _ready() -> void:
	RenderingServer.render_loop_enabled = false
	RenderingServer.call_on_render_thread(_setup_reader)
	viewport = SubViewport.new()
	viewport.size = Vector2i(160, 120)
	viewport.own_world_3d = true
	viewport.use_hdr_2d = true
	viewport.use_taa = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	add_child(viewport)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 3.0
	viewport.add_child(camera)
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	probe = Probe.new()
	environment.compositor = Compositor.new()
	environment.compositor.compositor_effects = [probe]
	viewport.add_child(environment)
	var background := MeshInstance3D.new()
	background.mesh = QuadMesh.new()
	background.mesh.size = Vector2(8.0, 8.0)
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment(){ALBEDO=vec3(1.0,0.0,0.0);}"
	background.material_override = material
	viewport.add_child(background)
	for phase: Array in [["native", Vector2i(160, 120), 1.0], ["half", Vector2i(160, 120), 0.5], ["supersample", Vector2i(160, 120), 1.5], ["odd_supersample", Vector2i(193, 131), 1.25]]:
		viewport.size = phase[1]
		viewport.scaling_3d_scale = phase[2]
		await _wait_for_pipelines()
		await _frames(4)
		camera.position.x += 0.11
		await _frames(1)
		var image := viewport.get_texture().get_image()
		var color := image.get_pixelv(viewport.size / 2)
		_check(image.get_size() == viewport.size and color.r > 0.85 and color.g < 0.1 and color.b < 0.1, phase[0] + "_pixels", color)
		var metadata: Dictionary = probe.metadata
		var expected_size := Vector2i(Vector2(viewport.size) * viewport.scaling_3d_scale)
		_check(metadata.get("taa", false) and metadata.get("format") == RenderingDevice.DATA_FORMAT_R16G16_SFLOAT and metadata.get("size") == expected_size and metadata.get("history_size") == expected_size, phase[0] + "_history_format_extent", metadata)
		read_complete = false
		RenderingServer.call_on_render_thread(_read_velocity.bind(metadata))
		var deadline := Time.get_ticks_msec() + 15000
		while not read_complete and Time.get_ticks_msec() < deadline: await get_tree().process_frame
		var valid: bool = read_complete and readback.size() == expected_size.x * expected_size.y * 4
		var maximum_error := 0.0
		var maximum_velocity := 0.0
		if valid:
			for index in range(0, readback.size(), 4):
				for axis in 2:
					var current := readback[index + axis]
					var history := readback[index + 2 + axis]
					valid = valid and is_finite(current) and is_finite(history)
					maximum_error = maxf(maximum_error, absf(current - history))
					maximum_velocity = maxf(maximum_velocity, absf(current))
		_check(valid and maximum_velocity > 0.001, phase[0] + "_motion_present", maximum_velocity)
		_check(valid and maximum_error == 0.0, phase[0] + "_exact_history_copy", maximum_error)
	RenderingServer.call_on_render_thread(_cleanup)

func _setup_reader() -> void:
	rd = RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D current_velocity;
layout(set=0,binding=1) uniform sampler2D history_velocity;
layout(set=0,binding=2,std430) restrict writeonly buffer Output { vec4 values[]; } output_data;
void main(){ivec2 pos=ivec2(gl_GlobalInvocationID.xy); ivec2 size=textureSize(current_velocity,0); if(any(greaterThanEqual(pos,size)))return; output_data.values[pos.y*size.x+pos.x]=vec4(texelFetch(current_velocity,pos,0).rg,texelFetch(history_velocity,pos,0).rg);}
"""
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_compute.is_empty(): push_error(spirv.compile_error_compute)
	shader = rd.shader_create_from_spirv(spirv, "TAA velocity readback probe")
	pipeline = rd.compute_pipeline_create(shader)
	sampler = rd.sampler_create(RDSamplerState.new())

func _read_velocity(metadata: Dictionary) -> void:
	var size: Vector2i = metadata["size"]
	var output := rd.storage_buffer_create(size.x * size.y * 16)
	var uniforms: Array[RDUniform] = []
	for index in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = index
		uniform.add_id(sampler)
		uniform.add_id(metadata["current" if index == 0 else "history"])
		uniforms.append(uniform)
	var buffer := RDUniform.new()
	buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer.binding = 2
	buffer.add_id(output)
	uniforms.append(buffer)
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, pipeline)
	rd.compute_list_bind_uniform_set(commands, uniform_set, 0)
	rd.compute_list_dispatch(commands, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	rd.compute_list_end()
	var data := rd.buffer_get_data(output)
	rd.free_rid(uniform_set)
	rd.free_rid(output)
	_read_done.call_deferred(data.to_float32_array())

func _read_done(values: PackedFloat32Array) -> void:
	readback = values
	read_complete = true

func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame
		var previous: int = probe.observed_frames
		RenderingServer.force_draw(false, 1.0 / 60.0)
		RenderingServer.force_sync()
		var deadline := Time.get_ticks_msec() + 5000
		while probe.observed_frames == previous and Time.get_ticks_msec() < deadline: await get_tree().process_frame
		if probe.observed_frames == previous: push_error("TAA compositor handoff timed out")

func _wait_for_pipelines() -> void:
	var stable := 0
	var previous := -1
	var deadline := Time.get_ticks_msec() + 60000
	while stable < 8 and Time.get_ticks_msec() < deadline:
		await _frames(1)
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]: requests += RenderingServer.get_rendering_info(source)
		stable = stable + 1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 and requests == previous else 0
		previous = requests
	if stable < 8: push_error("TAA pipelines did not settle")

func _check(condition: bool, label: String, detail: Variant = "") -> void:
	passed += int(condition)
	failed += int(not condition)
	print("TAA_INTEGRATION %s %s %s" % ["PASS" if condition else "FAIL", label, detail])

func _cleanup() -> void:
	for resource: RID in [sampler, pipeline, shader]: rd.free_rid(resource)
	_finish.call_deferred()

func _finish() -> void:
	print("TAA_INTEGRATION COMPLETE passed=%d failed=%d" % [passed, failed])
	get_tree().quit(0 if failed == 0 and passed == 16 else 1)
