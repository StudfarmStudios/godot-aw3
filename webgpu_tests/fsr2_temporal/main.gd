extends Node

const Probe = preload("res://probe.gd")
var viewport: SubViewport
var camera: Camera3D
var foreground: MeshInstance3D
var background_material: ShaderMaterial
var attributes: CameraAttributesPractical
var probe: CompositorEffect
var passed := 0
var failed := 0
var draw_count := 0
var output_directory := ""
var captures: Array[Dictionary] = []

func _ready() -> void:
	RenderingServer.render_loop_enabled = false
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--temporal-output="):
			output_directory = argument.trim_prefix("--temporal-output=")
	viewport = SubViewport.new()
	viewport.size = Vector2i(384, 256)
	viewport.own_world_3d = true
	viewport.use_hdr_2d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	viewport.scaling_3d_scale = 0.5
	viewport.fsr_sharpness = 0.2
	add_child(viewport)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 3.0
	attributes = CameraAttributesPractical.new()
	attributes.auto_exposure_speed = 10.0
	camera.attributes = attributes
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
	var background := MeshInstance3D.new()
	background.mesh = QuadMesh.new()
	background.mesh.size = Vector2(4.0, 4.0)
	background_material = ShaderMaterial.new()
	background_material.shader = Shader.new()
	background_material.shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; uniform vec3 test_color; uniform bool pattern_enabled = false; void fragment() { float checker = mod(floor(UV.x * 16.0) + floor(UV.y * 12.0), 2.0); ALBEDO = test_color * (pattern_enabled ? mix(0.1, 1.0, checker) : 1.0); }"
	background_material.set_shader_parameter("test_color", Vector3(1.0, 0.0, 0.0))
	background.material_override = background_material
	viewport.add_child(background)
	foreground = MeshInstance3D.new()
	foreground.mesh = QuadMesh.new()
	foreground.mesh.size = Vector2(0.62, 1.0)
	var foreground_material := ShaderMaterial.new()
	foreground_material.shader = Shader.new()
	foreground_material.shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment() { ALBEDO = vec3(0.0, 0.0, 1.0); }"
	foreground.material_override = foreground_material
	foreground.position = Vector3(-0.63, 0.0, 0.4)
	viewport.add_child(foreground)
	# Also warm the luminance-reduction variants before beginning the fixed timeline.
	attributes.auto_exposure_enabled = true
	await _wait_for_pipelines()
	attributes.auto_exposure_enabled = false
	# Force a new FSR context and align the controlled rasterizer frame count to
	# the 32-frame jitter period (2x upscale) after asynchronous warmup.
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	await _frames(1)
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	while draw_count % 32 != 0:
		await _frames(1)
	await _frames(32)
	_capture("motion_start", Color.RED, foreground.position.x)
	for step in 7:
		var previous_x := foreground.position.x
		foreground.position.x += 0.18
		await _frames(1)
		var image := _capture("motion_%02d" % step, Color.RED, foreground.position.x)
		# Midpoint of the newly revealed band, away from both moving boundaries.
		var revealed_x := previous_x - 0.31 + 0.09
		_check(_dominant(image, _world_pixel(revealed_x), 0, 0.55, 0.35), "motion_%02d_disocclusion" % step, image.get_pixelv(_world_pixel(revealed_x)))
	await _frames(16)
	_capture("motion_settled", Color.RED, foreground.position.x)
	foreground.visible = false
	background_material.set_shader_parameter("test_color", Vector3(0.0, 1.0, 0.0))
	await _frames(1)
	_capture("color_change_first", Color(), NAN)
	await _frames(4)
	_capture("color_change_five", Color.GREEN, NAN)
	await _frames(27)
	_capture("color_change_settled", Color.GREEN, NAN)
	# Nonuniform HDR input crosses six 64x64 SPD workgroups at 192x128.
	background_material.set_shader_parameter("pattern_enabled", true)
	background_material.set_shader_parameter("test_color", Vector3(0.05, 0.05, 0.05))
	await _frames(32)
	var dim_image := _capture("luminance_dim", Color(), NAN)
	background_material.set_shader_parameter("test_color", Vector3(4.0, 4.0, 4.0))
	await _frames(1)
	_capture("luminance_bright_first", Color(), NAN)
	await _frames(31)
	var bright_image := _capture("luminance_bright_settled", Color(), NAN)
	var hdr_gain := _mean_red(bright_image) / _mean_red(dim_image)
	_check(hdr_gain > 70.0 and hdr_gain < 90.0, "luminance_hdr_gain", hdr_gain)
	attributes.auto_exposure_enabled = true
	await _frames(32)
	var bright_exposure := _mean_red(_capture("auto_exposure_bright", Color(), NAN))
	# Bright luminance is clamped to 1; exposure scale 0.4 maps mean 2.2 to ~0.88.
	_check(bright_exposure > 0.75 and bright_exposure < 1.0, "auto_exposure_bright_mean", bright_exposure)
	background_material.set_shader_parameter("test_color", Vector3(0.05, 0.05, 0.05))
	await _frames(32)
	var dim_exposure := _mean_red(_capture("auto_exposure_dim", Color(), NAN))
	# Mean input 0.0275, luminance starts at 1, adaptation factor 10/60.
	# After 32 frames: 0.0275 * 0.4 / (0.0275 + 0.9725 * (5/6)^32) ~= 0.362.
	_check(dim_exposure > 0.30 and dim_exposure < 0.42, "auto_exposure_dim_mean", dim_exposure)
	attributes.auto_exposure_enabled = false
	background_material.set_shader_parameter("pattern_enabled", false)
	background_material.set_shader_parameter("test_color", Vector3(0.0, 0.0, 1.0))
	# Partial SPD workgroups after resize: internal258x194, 5x4 groups.
	viewport.size = Vector2i(516, 388)
	await _frames(1)
	_capture("resize_reset_first", Color.BLUE, NAN)
	await _frames(31)
	_capture("resize_reset_settled", Color.BLUE, NAN)
	var manifest := {"captures": captures, "draw_count": draw_count, "passed": passed, "failed": failed, "driver": RenderingServer.get_current_rendering_driver_name(), "device": RenderingServer.get_video_adapter_name()}
	var file := FileAccess.open(output_directory.path_join("manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "\t"))
	print("FSR2_TEMPORAL COMPLETE passed=%d failed=%d captures=%d" % [passed, failed, captures.size()])
	get_tree().quit(0 if failed == 0 else 1)

func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame
		var previous_metadata_frame: int = probe.observed_frames
		RenderingServer.force_draw(false, 1.0 / 60.0)
		RenderingServer.force_sync()
		draw_count += 1
		# The compositor publishes on the main thread; synchronize that value
		# handoff without rendering an additional frame (especially after resize).
		var metadata_deadline := Time.get_ticks_msec() + 5000
		while probe.observed_frames == previous_metadata_frame and Time.get_ticks_msec() < metadata_deadline:
			await get_tree().process_frame
		if probe.observed_frames == previous_metadata_frame:
			push_error("FSR2 compositor metadata handoff timed out")

func _wait_for_pipelines() -> void:
	var stable := 0
	var previous := -1
	var deadline := Time.get_ticks_msec() + 60000
	while stable < 8 and Time.get_ticks_msec() < deadline:
		await _frames(1)
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]:
			requests += RenderingServer.get_rendering_info(source)
		stable = stable + 1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 and requests == previous else 0
		previous = requests
	_check(stable >= 8, "pipeline_warmup", RenderingServer.get_pending_pipeline_compilation_count())

func _world_pixel(x: float) -> Vector2i:
	return Vector2i(roundi(viewport.size.x * 0.5 + x * viewport.size.y * 0.5), viewport.size.y / 2)

func _dominant(image: Image, position: Vector2i, channel: int, minimum := 0.7, maximum_other := 0.2) -> bool:
	var pixel := image.get_pixelv(position)
	var channels := [pixel.r, pixel.g, pixel.b]
	var valid: bool = channels[channel] > minimum
	for other in 3:
		if other != channel:
			valid = valid and abs(channels[other]) < maximum_other
	return valid

func _mean_red(image: Image) -> float:
	var values := image.get_data().to_float32_array()
	var total := 0.0
	for index in range(0, values.size(), 4):
		total += values[index]
	return total / (image.get_width() * image.get_height())

func _capture(label: String, expected: Color, foreground_x: float) -> Image:
	var image := viewport.get_texture().get_image()
	var size := viewport.size
	_check(image != null and image.get_size() == size, label + "_extent")
	var finite := true
	var minimum := INF
	var maximum := -INF
	for y in range(0, size.y, 4):
		for x in range(0, size.x, 4):
			var pixel := image.get_pixel(x, y)
			for value: float in [pixel.r, pixel.g, pixel.b]:
				finite = finite and is_finite(value) and value >= -0.05 and value < 64.0
				minimum = minf(minimum, value)
				maximum = maxf(maximum, value)
	_check(finite, label + "_finite", [minimum, maximum])
	if expected != Color():
		var channel := 0 if expected == Color.RED else (1 if expected == Color.GREEN else 2)
		_check(_dominant(image, Vector2i(size.x / 2, size.y / 8), channel), label + "_background")
	if is_finite(foreground_x):
		_check(_dominant(image, _world_pixel(foreground_x), 2), label + "_foreground")
	var metadata: Dictionary = probe.metadata
	_check(metadata.get("mode") == RenderingServer.VIEWPORT_SCALING_3D_MODE_FSR2 and metadata.get("target_size") == size and metadata.get("internal_size", Vector2i.ZERO).x > 64 and metadata.get("internal_size", Vector2i.ZERO).y > 64, label + "_actual_fsr2", metadata)
	image.convert(Image.FORMAT_RGBAF)
	var file := FileAccess.open(output_directory.path_join(label + ".rgba32f"), FileAccess.WRITE)
	file.store_buffer(image.get_data())
	image.save_png(output_directory.path_join(label + ".png"))
	captures.append({"label": label, "width": size.x, "height": size.y, "draw_frame": draw_count, "minimum": minimum, "maximum": maximum, "mean_red": _mean_red(image), "internal_size": [metadata.get("internal_size", Vector2i.ZERO).x, metadata.get("internal_size", Vector2i.ZERO).y]})
	print("FSR2_TEMPORAL CAPTURE %s frame=%d min=%f max=%f" % [label, draw_count, minimum, maximum])
	return image

func _check(condition: bool, label: String, detail: Variant = "") -> void:
	if condition:
		passed += 1
		print("FSR2_TEMPORAL PASS %s" % label)
	else:
		failed += 1
		print("FSR2_TEMPORAL FAIL %s %s" % [label, detail])
