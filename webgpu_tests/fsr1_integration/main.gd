extends Node

const Probe = preload("res://probe.gd")
const XRTarget = preload("res://xr_target.gd")
var passed := 0
var failed := 0
var viewport: SubViewport
var material: ShaderMaterial
var probe: CompositorEffect
var output_directory := ""

func _ready() -> void:
	# Native CI windows may be occluded; drive offscreen frames explicitly.
	RenderingServer.render_loop_enabled = false
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--fsr1-output="):
			output_directory = argument.trim_prefix("--fsr1-output=")
	get_tree().create_timer(90.0).timeout.connect(func():
		print("FSR1_TEST timeout")
		get_tree().quit(2))
	viewport = SubViewport.new()
	viewport.size = Vector2i(95, 61)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
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
	probe = Probe.new()
	environment.compositor = Compositor.new()
	environment.compositor.compositor_effects = [probe]
	viewport.add_child(environment)
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.mesh.size = Vector2(4.0, 4.0)
	material = ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; uniform vec3 test_color; void fragment() { ALBEDO = test_color; }"
	mesh.material_override = material
	viewport.add_child(mesh)
	await _phase("sdr_red", Vector2i(95, 61), false, Color.RED, 0)
	await _phase("sdr_green", Vector2i(95, 61), false, Color.GREEN, 1)
	await _phase("hdr_blue", Vector2i(97, 63), true, Color.BLUE, 2)
	viewport.scaling_3d_scale = 0.67
	await _phase("hdr_resize_red", Vector2i(127, 79), true, Color.RED, 0)
	var xr_target := XRTarget.new()
	XRServer.add_interface(xr_target)
	xr_target.initialize()
	XRServer.primary_interface = xr_target
	# A new size clears the prior FSR context so the direct case proves that it
	# does not allocate an unused RCAS intermediate.
	xr_target.configure_target(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector2i(111, 69))
	await xr_target.target_ready
	viewport.use_xr = true
	await _phase("storage_rgba16f_direct", Vector2i(111, 69), true, Color.GREEN, 1, xr_target, false)
	viewport.use_xr = false
	xr_target.configure_target(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, Vector2i(113, 71))
	await xr_target.target_ready
	viewport.use_xr = true
	await _phase("storage_rgba8_converted", Vector2i(113, 71), true, Color.BLUE, 2, xr_target, true)
	viewport.use_xr = false
	XRServer.primary_interface = null
	xr_target.uninitialize()
	XRServer.remove_interface(xr_target)
	xr_target.release_target()
	await get_tree().process_frame
	print("FSR1_TEST COMPLETE passed=%d failed=%d" % [passed, failed])
	get_tree().quit(0 if failed == 0 else 1)

func _check(condition: bool, label: String, detail: Variant = "") -> void:
	if condition:
		passed += 1
		print("FSR1_TEST PASS %s" % label)
	else:
		failed += 1
		print("FSR1_TEST FAIL %s %s" % [label, detail])

func _wait_for_pipelines(label: String) -> bool:
	# Check the engine's actual async queue, never use expected pixels as a
	# warmup condition. Extra settled frames let the now-ready FSR passes run.
	var started := Time.get_ticks_msec()
	var previous_requests := -1
	var stable_frames := 0
	var frames := 0
	while Time.get_ticks_msec() - started < 30000:
		await get_tree().process_frame
		RenderingServer.force_draw(false, 1.0 / 60.0)
		RenderingServer.force_sync()
		frames += 1
		var pending := RenderingServer.get_pending_pipeline_compilation_count()
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]:
			requests += RenderingServer.get_rendering_info(source)
		stable_frames = stable_frames + 1 if pending == 0 and requests == previous_requests else 0
		previous_requests = requests
		if frames >= 8 and stable_frames >= 4:
			print("FSR1_TEST READY %s frames=%d milliseconds=%d pending=%d requests=%d" % [label, frames, Time.get_ticks_msec() - started, pending, requests])
			return true
	_check(false, label + "_pipeline_timeout", RenderingServer.get_pending_pipeline_compilation_count())
	return false

func _phase(label: String, size: Vector2i, hdr: bool, color: Color, dominant_channel: int, xr_target = null, expect_rcas := true) -> void:
	viewport.size = size
	viewport.use_hdr_2d = hdr
	material.set_shader_parameter("test_color", Vector3(color.r, color.g, color.b))
	if not await _wait_for_pipelines(label):
		return
	var image: Image
	if xr_target == null:
		image = viewport.get_texture().get_image()
	else:
		xr_target.read_image()
		image = await xr_target.image_ready
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
	var metadata: Dictionary = probe.metadata
	_check(metadata.get("target_size") == size and metadata.get("scaling_mode") == RenderingServer.VIEWPORT_SCALING_3D_MODE_FSR and metadata.get("internal_size", size).x < size.x, label + "_actual_fsr_scaling", metadata)
	for buffer_name: String in ["upscale", "rcas"]:
		var buffer: Dictionary = metadata.get(buffer_name, {})
		if buffer_name == "rcas" and not expect_rcas:
			_check(buffer.is_empty(), label + "_rcas_not_allocated", buffer)
			continue
		_check(buffer.get("format") == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT and buffer.get("width") == size.x and buffer.get("height") == size.y and buffer.get("layers") == 1 and (buffer.get("usage", 0) & RenderingDevice.TEXTURE_USAGE_STORAGE_BIT) != 0, label + "_" + buffer_name + "_format_extent", buffer)
	print("FSR1_TEST METADATA %s %s" % [label, metadata])
