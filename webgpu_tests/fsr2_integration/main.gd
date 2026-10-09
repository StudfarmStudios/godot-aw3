extends Node

var passed := 0
var failed := 0
var viewport: SubViewport
var material: ShaderMaterial
var output_directory := ""

func _ready() -> void:
	# Drive offscreen frames even when the native window is occluded.
	RenderingServer.render_loop_enabled = false
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--fsr2-output="):
			output_directory = argument.trim_prefix("--fsr2-output=")
	get_tree().create_timer(90.0).timeout.connect(func():
		print("FSR2_TEST timeout")
		get_tree().quit(2))
	viewport = SubViewport.new()
	viewport.size = Vector2i(320, 256)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	viewport.scaling_3d_scale = 0.5
	add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 3.0
	viewport.add_child(camera)
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	viewport.add_child(environment)
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.mesh.size = Vector2(4.0, 4.0)
	material = ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; uniform vec3 test_color; void fragment() { ALBEDO = test_color; }"
	mesh.material_override = material
	viewport.add_child(mesh)
	await _phase("sdr_red", Vector2i(320, 256), false, Color.RED, 0)
	await _phase("sdr_green", Vector2i(320, 256), false, Color.GREEN, 1)
	await _phase("hdr_blue", Vector2i(322, 258), true, Color.BLUE, 2)
	viewport.scaling_3d_scale = 0.67
	await _phase("hdr_resize_red", Vector2i(385, 287), true, Color.RED, 0)
	print("FSR2_TEST COMPLETE passed=%d failed=%d" % [passed, failed])
	get_tree().quit(0 if failed == 0 else 1)

func _check(condition: bool, label: String, detail: Variant = "") -> void:
	if condition:
		passed += 1
		print("FSR2_TEST PASS %s" % label)
	else:
		failed += 1
		print("FSR2_TEST FAIL %s %s" % [label, detail])

func _phase(label: String, size: Vector2i, hdr: bool, color: Color, dominant_channel: int) -> void:
	viewport.size = size
	viewport.use_hdr_2d = hdr
	material.set_shader_parameter("test_color", Vector3(color.r, color.g, color.b))
	# Wait for actual compiler completion, then let temporal history converge.
	# Expected pixels never drive readiness, so a black frame still fails.
	var stable_frames := 0
	var previous_requests := -1
	var deadline := Time.get_ticks_msec() + 60000
	while stable_frames < 32 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		RenderingServer.force_draw(false, 1.0 / 60.0)
		RenderingServer.force_sync()
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]:
			requests += RenderingServer.get_rendering_info(source)
		var pending: int = RenderingServer.get_pending_pipeline_compilation_count()
		stable_frames = stable_frames + 1 if pending == 0 and requests == previous_requests else 0
		previous_requests = requests
	if stable_frames < 32:
		push_error("FSR2 pipeline drain timed out")
	print("FSR2_TEST PIPELINES %s stable=%d requests=%d" % [label, stable_frames, previous_requests])
	var image := viewport.get_texture().get_image()
	_check(image != null and image.get_size() == size, label + "_image_size")
	if image == null or image.is_empty():
		_check(false, label + "_pixels", "empty image")
	else:
		var valid := true
		var sample_text := []
		for fraction: Vector2 in [Vector2(0.02, 0.02), Vector2(0.98, 0.02), Vector2(0.5, 0.5), Vector2(0.02, 0.98), Vector2(0.98, 0.98)]:
			var pixel := image.get_pixel(int((size.x - 1) * fraction.x), int((size.y - 1) * fraction.y))
			var channels := [pixel.r, pixel.g, pixel.b]
			valid = valid and is_finite(channels[dominant_channel]) and channels[dominant_channel] > 0.75
			for channel in 3:
				if channel != dominant_channel:
					valid = valid and is_finite(channels[channel]) and abs(channels[channel]) < 0.08
			sample_text.append(pixel)
		_check(valid, label + "_pixels", sample_text)
		if not output_directory.is_empty():
			image.save_png(output_directory.path_join(label + ".png"))
