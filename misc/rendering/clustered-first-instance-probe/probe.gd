extends Node

# Static deterministic coverage for Forward Clustered's guarded firstInstance
# and push-constant reuse path. This fixture deliberately has no TIME, random,
# animation, particles, lighting, or temporal anti-aliasing inputs.

const VIEW_SIZE := Vector2i(720, 480)
const FIXED_FPS := 60
const PREWARM_FRAMES := 90
const PIPELINE_QUIESCENT_FRAMES := 3
const MAX_PIPELINE_WAIT_MSEC := 45_000
const SETTLE_FRAMES := 8
const COUNTER_SAMPLE_MSEC := 3_000
const HARD_TIMEOUT_MSEC := 180_000
const MIN_FOREGROUND_PIXELS := 2_000
const FOREGROUND_COLOR_DELTA := 0.045
const CAPTURE_LABELS := ["center", "left", "right"]

const BACKGROUND := Color(0.008, 0.012, 0.022, 1.0)
const INSTANCE_ID_COLOR := Color(0.10, 0.95, 0.24, 1.0)
const REPEAT_COLOR := Color(0.12, 0.42, 1.0, 1.0)
const MULTIMESH_COLOR := Color(0.98, 0.22, 0.12, 1.0)
const POINT_COLOR := Color(1.0, 0.86, 0.12, 1.0)
const LIT_COLOR := Color(0.86, 0.80, 0.68, 1.0)
const RECEIVER_COLOR := Color(0.32, 0.34, 0.40, 1.0)

const ORDINARY_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
instance uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
	ALBEDO = tint.rgb;
}
"""

const INSTANCE_ID_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
void vertex() {
	// Every draw below has one instance. Godot's documented INSTANCE_ID is
	// therefore zero even when scene-instance data lives at a nonzero index.
	VERTEX.x += float(INSTANCE_ID) * 40.0;
}
void fragment() {
	ALBEDO = vec3(0.10, 0.95, 0.24);
}
"""

const TRANSPARENT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
instance uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
	ALBEDO = tint.rgb;
	ALPHA = tint.a;
}
"""

const LIT_SHADER := """
shader_type spatial;
render_mode cull_disabled;
instance uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
	ALBEDO = tint.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
"""

const POINT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
void vertex() {
	POINT_SIZE = 22.0;
}
void fragment() {
	ALBEDO = vec3(1.0, 0.86, 0.12);
}
"""

var _output := "user://clustered-first-instance-probe"
var _viewport: SubViewport
var _camera: Camera3D
var _started := false
var _deadline_msec := 0
var _shutdown_frames := -1
var _shutdown_exit_code := 0
var _prewarm_frame := 0
var _pipeline_wait_frames := 0
var _pipeline_wait_started_msec := -1
var _pipeline_wait_elapsed_msec := 0
var _pipeline_zero_frames := 0
var _counter_sample_frames := 0
var _counter_sample_started_msec := -1
var _counter_sample_elapsed_msec := 0
var _counter_sample_complete := false
var _pose_index := 0
var _settle_frames := 0
var _draw_pending := false
var _capture_pending := false
var _capture_flushes := 0
var _capture_wait_frames := 0
var _capture_attempts := 0
var _hashes: Dictionary = {}
var _foreground: Dictionary = {}
var _samples: Dictionary = {}
var _failures: Array[String] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")
	var absolute_output := ProjectSettings.globalize_path(_output)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(absolute_output)
	if mkdir_error != OK:
		_fail("cannot create output directory %s: %s" % [absolute_output, error_string(mkdir_error)])
		return
	_deadline_msec = Time.get_ticks_msec() + HARD_TIMEOUT_MSEC
	_build_fixture()
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	call_deferred("_start_probe")


func _start_probe() -> void:
	_started = true
	_apply_pose(0)
	print("CLUSTERED_FIRST_INSTANCE start renderer=%s driver=%s adapter=%s output=%s" % [
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name(),
		ProjectSettings.globalize_path(_output),
	])


func _process(_delta: float) -> void:
	if _shutdown_frames >= 0:
		if _shutdown_frames == 0:
			get_tree().quit(_shutdown_exit_code)
		else:
			_shutdown_frames -= 1
		return
	if Time.get_ticks_msec() >= _deadline_msec:
		_fail("hard timeout after %d ms" % HARD_TIMEOUT_MSEC)
		return
	if not _started:
		return
	if _capture_pending:
		_poll_capture()
		return

	if _prewarm_frame < PREWARM_FRAMES:
		_prewarm_frame += 1
		return

	if _pipeline_zero_frames < PIPELINE_QUIESCENT_FRAMES:
		var now_msec := Time.get_ticks_msec()
		if _pipeline_wait_started_msec < 0:
			_pipeline_wait_started_msec = now_msec
		var pending := RenderingServer.get_pending_pipeline_compilation_count()
		_pipeline_wait_frames += 1
		if pending == 0:
			_pipeline_zero_frames += 1
		else:
			_pipeline_zero_frames = 0
		_pipeline_wait_elapsed_msec = now_msec - _pipeline_wait_started_msec
		if _pipeline_wait_elapsed_msec >= MAX_PIPELINE_WAIT_MSEC:
			_fail("pipeline compilation did not become quiescent in %d ms; pending=%d polls=%d" % [_pipeline_wait_elapsed_msec, pending, _pipeline_wait_frames])
			return
		if _pipeline_zero_frames < PIPELINE_QUIESCENT_FRAMES:
			return

	if not _counter_sample_complete:
		var now_msec := Time.get_ticks_msec()
		if _counter_sample_started_msec < 0:
			_counter_sample_started_msec = now_msec
			print("CLUSTERED_FIRST_INSTANCE_COUNTERS_BEGIN")
		_counter_sample_frames += 1
		_counter_sample_elapsed_msec = now_msec - _counter_sample_started_msec
		if _counter_sample_elapsed_msec < COUNTER_SAMPLE_MSEC:
			return
		_counter_sample_complete = true
		print("CLUSTERED_FIRST_INSTANCE_COUNTERS_END elapsed_ms=%d frames=%d" % [_counter_sample_elapsed_msec, _counter_sample_frames])

	if _draw_pending:
		# A post-draw callback must consume every requested capture draw.
		_fail("frame_post_draw skipped pose %s" % CAPTURE_LABELS[_pose_index])
		return

	if _settle_frames < SETTLE_FRAMES:
		_settle_frames += 1
		return

	_draw_pending = true


func _on_frame_post_draw() -> void:
	if not _draw_pending or _capture_pending:
		return
	_draw_pending = false
	_capture_pending = true
	_capture_flushes = 0
	_capture_wait_frames = 0
	_capture_attempts = 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _poll_capture() -> void:
	if _capture_wait_frames > 0:
		_capture_wait_frames -= 1
		return
	if _capture_flushes < 2:
		_viewport.get_texture().get_image()
		_capture_flushes += 1
		_capture_wait_frames = 3
		return

	var image := _viewport.get_texture().get_image()
	_capture_attempts += 1
	if image == null or image.is_empty():
		if _capture_attempts >= 120:
			_fail("readback timed out for pose %s" % CAPTURE_LABELS[_pose_index])
		return
	image.convert(Image.FORMAT_RGBA8)
	var label: String = CAPTURE_LABELS[_pose_index]
	var count := _count_foreground(image)
	if count < MIN_FOREGROUND_PIXELS:
		_fail("pose %s is blank: foreground=%d require=%d" % [label, count, MIN_FOREGROUND_PIXELS])
		return

	# Samples are taken from the fixed center pose only. The INSTANCE_ID sample
	# detects an accidental nonzero firstInstance, while the other samples prove
	# the repeated, MultiMesh, and point-size exclusions remained visible.
	if _pose_index == 0:
		_check_known_color(image, "instance_id", Vector2(0.30, 0.50), INSTANCE_ID_COLOR)
		_check_known_color(image, "repeat", Vector2(0.253, 0.80), REPEAT_COLOR)
		_check_known_color(image, "multimesh", Vector2(0.727, 0.80), MULTIMESH_COLOR)
		_check_known_color(image, "point", Vector2(0.933, 0.50), POINT_COLOR)
		if not _failures.is_empty():
			_begin_shutdown(2)
			return

	var path := "%s/%s.png" % [_output, label]
	var save_error := image.save_png(path)
	if save_error != OK:
		_fail("cannot save %s: %s" % [path, error_string(save_error)])
		return
	_hashes[label] = FileAccess.get_sha256(path)
	_foreground[label] = count
	print("CLUSTERED_FIRST_INSTANCE pose=%s sha256=%s foreground=%d" % [label, _hashes[label], count])

	_capture_pending = false
	_pose_index += 1
	if _pose_index == CAPTURE_LABELS.size():
		_finish()
		return
	_apply_pose(_pose_index)
	_settle_frames = 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _build_fixture() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "FirstInstanceViewport"
	_viewport.size = VIEW_SIZE
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.use_taa = false
	add_child(_viewport)

	var world := Node3D.new()
	world.name = "FixtureWorld"
	_viewport.add_child(world)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = BACKGROUND
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	world.add_child(environment)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 10.0
	_camera.position = Vector3(0.0, 0.0, 14.0)
	_camera.current = true
	world.add_child(_camera)

	var ordinary := _make_shader_material(ORDINARY_SHADER)
	var instance_id := _make_shader_material(INSTANCE_ID_SHADER)
	var transparent := _make_shader_material(TRANSPARENT_SHADER)
	var point := _make_shader_material(POINT_SHADER)

	# Unique mesh RIDs force singleton draw elements. Their non-base-index push
	# constants are identical, while per-instance colors live in instance data.
	for index in range(12):
		var hue := float(index) / 12.0
		var color := Color.from_hsv(hue, 0.72, 0.95)
		_add_box(world, "Singleton%02d" % index, Vector3(-6.6 + index * 1.2, 3.0, 0.0), ordinary, color)

	# INSTANCE_ID must remain zero for every singleton draw. Each box uses a
	# unique mesh RID so it cannot enter the existing repeated-instance batch.
	for index in range(5):
		_add_box(world, "InstanceId%02d" % index, Vector3(-5.7 + index * 1.35, 0.0, 0.0), instance_id, INSTANCE_ID_COLOR)

	# Existing same-mesh batching is a negative control for this candidate.
	var repeated_mesh := _make_box_mesh(0.74, ordinary)
	for index in range(6):
		var node := MeshInstance3D.new()
		node.name = "Repeated%02d" % index
		node.mesh = repeated_mesh
		node.position = Vector3(-6.0 + index * 1.15, -3.0, 0.0)
		node.set_instance_shader_parameter("tint", REPEAT_COLOR)
		world.add_child(node)

	# Singleton transparent draws remain in their authored depth order. Unique
	# QuadMesh RIDs prevent the preexisting repeated-instance batch.
	var transparent_colors: Array[Color] = [
		Color(1.0, 0.12, 0.16, 0.34),
		Color(0.12, 1.0, 0.25, 0.34),
		Color(0.18, 0.32, 1.0, 0.34),
	]
	for index in range(3):
		var quad := MeshInstance3D.new()
		quad.name = "Transparent%02d" % index
		quad.mesh = _make_quad_mesh(2.0, transparent)
		quad.position = Vector3(3.1, 0.0, 0.24 - index * 0.24)
		var transparent_color: Color = transparent_colors[index]
		quad.set_instance_shader_parameter("tint", transparent_color)
		world.add_child(quad)

	_add_multimesh(world, ordinary)
	_add_point_mesh(world, point)

	# Shadow coverage. Shadow passes are not excluded from the candidate, so
	# singleton casters take the firstInstance path there too. A lit shader
	# (no "unshaded") puts these draws in the lit and shadow lists; unique mesh
	# RIDs keep each one a singleton draw. The receiver makes the shadow itself
	# part of the captured image, so a wrong instance offset moves visible
	# geometry rather than only changing an off-screen depth buffer.
	var lit := _make_shader_material(LIT_SHADER)
	var receiver := MeshInstance3D.new()
	receiver.name = "ShadowReceiver"
	receiver.mesh = _make_quad_mesh(9.0, lit)
	receiver.position = Vector3(0.0, 0.0, -2.6)
	receiver.set_instance_shader_parameter("tint", RECEIVER_COLOR)
	world.add_child(receiver)

	for index in range(4):
		var caster := MeshInstance3D.new()
		caster.name = "ShadowCaster%02d" % index
		caster.mesh = _make_box_mesh(0.62 + index * 0.02, lit)
		caster.position = Vector3(-2.7 + index * 1.8, 1.5, 0.9)
		caster.set_instance_shader_parameter("tint", LIT_COLOR)
		world.add_child(caster)

	var sun := DirectionalLight3D.new()
	sun.name = "ShadowSun"
	sun.shadow_enabled = true
	sun.light_energy = 1.4
	sun.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(24.0), 0.0)
	world.add_child(sun)

	assert(world.get_child_count() == 36)
	assert(_viewport.find_world_3d() == world.get_world_3d())


func _make_shader_material(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _make_box_mesh(size: float, material: Material) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, size, 0.28)
	mesh.material = material
	return mesh


func _make_quad_mesh(size: float, material: Material) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	mesh.orientation = PlaneMesh.FACE_Z
	mesh.material = material
	return mesh


func _add_box(parent: Node3D, node_name: String, position: Vector3, material: Material, color: Color) -> void:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = _make_box_mesh(0.78, material)
	node.position = position
	node.set_instance_shader_parameter("tint", color)
	parent.add_child(node)


func _add_multimesh(parent: Node3D, material: Material) -> void:
	var mesh := _make_box_mesh(0.72, material)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = false
	multimesh.instance_count = 4
	for index in range(4):
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3(index * 0.92, 0.0, 0.0)))
	var node := MultiMeshInstance3D.new()
	node.name = "MultiMeshControl"
	node.multimesh = multimesh
	node.multimesh.mesh = mesh
	node.position = Vector3(3.4, -3.0, 0.0)
	node.set_instance_shader_parameter("tint", MULTIMESH_COLOR)
	parent.add_child(node)


func _add_point_mesh(parent: Node3D, material: Material) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh.surface_set_material(0, material)
	var node := MeshInstance3D.new()
	node.name = "PointSizeControl"
	node.mesh = mesh
	node.custom_aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	node.position = Vector3(6.5, 0.0, 0.0)
	parent.add_child(node)


func _apply_pose(index: int) -> void:
	var positions := [
		Vector3(0.0, 0.0, 14.0),
		Vector3(-0.6, 0.25, 14.0),
		Vector3(0.7, -0.20, 14.0),
	]
	_camera.position = positions[index]
	_camera.rotation = Vector3.ZERO


func _count_foreground(image: Image) -> int:
	var background := image.get_pixel(0, 0)
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			var delta := absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b)
			if delta > FOREGROUND_COLOR_DELTA:
				count += 1
	return count


func _check_known_color(image: Image, name: String, uv: Vector2, expected: Color) -> void:
	var point := Vector2i(int(round(uv.x * float(image.get_width() - 1))), int(round(uv.y * float(image.get_height() - 1))))
	var actual := image.get_pixelv(point)
	_samples[name] = {
		"pixel": [point.x, point.y],
		"rgba": [actual.r, actual.g, actual.b, actual.a],
	}
	# Compare chromaticity rather than raw channel values so the assertion is
	# independent of the backend's linear-to-output transfer function.
	var actual_sum := actual.r + actual.g + actual.b
	var expected_sum := expected.r + expected.g + expected.b
	var chroma_delta := 3.0
	if actual_sum > 0.0:
		chroma_delta = (
			absf(actual.r / actual_sum - expected.r / expected_sum) +
			absf(actual.g / actual_sum - expected.g / expected_sum) +
			absf(actual.b / actual_sum - expected.b / expected_sum)
		)
	if maxf(actual.r, maxf(actual.g, actual.b)) < 0.55 or chroma_delta > 0.55:
		_failures.append("sample %s at %s chroma_delta=%.6f actual=%s expected=%s" % [name, point, chroma_delta, actual, expected])


func _finish() -> void:
	if _hashes.size() != CAPTURE_LABELS.size():
		_fail("capture set incomplete: got=%d expected=%d" % [_hashes.size(), CAPTURE_LABELS.size()])
		return
	var metadata := {
		"format": 1,
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"required_fixed_fps": FIXED_FPS,
		"viewport_size": [VIEW_SIZE.x, VIEW_SIZE.y],
		"prewarm_frames": PREWARM_FRAMES,
		"pipeline_wait_frames": _pipeline_wait_frames,
		"pipeline_wait_elapsed_msec": _pipeline_wait_elapsed_msec,
		"pipeline_quiescent_frames": PIPELINE_QUIESCENT_FRAMES,
		"counter_sample_frames": _counter_sample_frames,
		"counter_sample_elapsed_msec": _counter_sample_elapsed_msec,
		"settle_frames_per_pose": SETTLE_FRAMES,
		"capture_labels": CAPTURE_LABELS,
		"sha256": _hashes,
		"foreground": _foreground,
		"known_color_samples": _samples,
		"coverage": [
			"unique-mesh opaque singleton draws eligible for firstInstance",
			"INSTANCE_ID singleton draws excluded from firstInstance",
			"existing same-mesh repeated-instance batch",
			"ordered singleton transparent draws",
			"MultiMesh exclusion",
			"point-size/emulation exclusion",
			"lit singleton casters with a directional shadow pass",
		],
		"failures": _failures,
	}
	var file := FileAccess.open("%s/metadata.json" % _output, FileAccess.WRITE)
	if file == null:
		_fail("cannot write metadata: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify(metadata, "\t") + "\n")
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_fail("metadata write failed: %s" % error_string(write_error))
		return
	print("CLUSTERED_FIRST_INSTANCE_DONE captures=%d output=%s" % [_hashes.size(), ProjectSettings.globalize_path(_output)])
	_begin_shutdown(0)


func _fail(message: String) -> void:
	_failures.append(message)
	push_error("CLUSTERED_FIRST_INSTANCE " + message)
	_begin_shutdown(2)


func _begin_shutdown(exit_code: int) -> void:
	_started = false
	_shutdown_exit_code = exit_code
	_shutdown_frames = 2
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
