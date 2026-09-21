extends Node

# The fixture has no TIME input and no random shader operations. Particle layout
# comes only from INDEX, and every emitter is restarted from a fixed seed after
# all pipelines have warmed.

const VIEW_SIZE := Vector2i(480, 360)
const FIXED_FPS := 60
const PREWARM_FRAMES := 90
const PIPELINE_QUIESCENT_FRAMES := 3
const MAX_PIPELINE_WAIT_FRAMES := 600
const LAST_FRAME := 119
const CAPTURE_FRAMES := [0, 1, 2, 3, 8, 16, 30, 45, 60, 90, 119]
const MIN_FOREGROUND_PIXELS := 128
const FOREGROUND_COLOR_DELTA := 0.04
const HARD_TIMEOUT_MSEC := 180_000
const FILLER_INSTANCE_COUNT := 512
const SERIAL_THRESHOLD := 65_536
const THREADED_THRESHOLD := 32
const SEEDS := {
	"depth": 0x13579BDF,
	"billboard": 0x2468ACE0,
	"local": 0x10203040,
}

const PARTICLE_SHADER := """
shader_type particles;
render_mode disable_force;

uniform float system_offset = 0.0;

void start() {
	float id = float(INDEX);
	float u = fract(id * 0.61803398875 + system_offset * 0.173);
	float v = fract(id * 0.41421356237 + system_offset * 0.311);
	float w = fract(id * 0.73205080757 + system_offset * 0.197);
	if (RESTART_ROT_SCALE) {
		TRANSFORM[0] = vec4(1.0, 0.0, 0.0, 0.0);
		TRANSFORM[1] = vec4(0.0, 1.0, 0.0, 0.0);
		TRANSFORM[2] = vec4(0.0, 0.0, 1.0, 0.0);
	}
	if (RESTART_POSITION) {
		TRANSFORM[3] = vec4((u - 0.5) * 2.8, (v - 0.5) * 2.5, (w - 0.5) * 3.2, 1.0);
	}
	if (RESTART_VELOCITY) {
		VELOCITY = normalize(vec3(0.3 + u, 0.45 + v, -0.35 + w)) * 0.035;
	}
	if (RESTART_COLOR) {
		COLOR = vec4(0.25 + 0.75 * u, 0.2 + 0.8 * v, 0.3 + 0.7 * w, 0.42);
	}
	if (RESTART_CUSTOM) {
		CUSTOM = vec4((u - 0.5) * 1.7, v, w, 0.0);
	}
}

void process() {
	TRANSFORM[3].xyz += VELOCITY * DELTA;
}
"""

var _main_viewport: SubViewport
var _alternate_viewport: SubViewport
var _main_camera: Camera3D
var _alternate_camera: Camera3D
var _particles: Array[GPUParticles3D] = []

var _output := "user://particle-cull-order-probe"
var _mode := ""
var _started := false
var _shutdown_frames := -1
var _shutdown_exit_code := 0
var _deadline_msec := 0
var _prewarm_frame := 0
var _pipeline_wait_frames := 0
var _pipeline_zero_frames := 0
var _sequence_frame := 0
var _draw_label := -1
var _capture_label := -1
var _capture_flushes := 0
var _capture_wait_frames := 0
var _capture_attempts := 0
var _resume_next_frame := false
var _confirmed_draws := 0
var _hashes := { "main": {}, "alternate": {} }


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")

	var serial := OS.has_feature("particle_cull_serial")
	var threaded := OS.has_feature("particle_cull_threaded")
	if serial == threaded:
		_fail("exactly one custom feature is required: particle_cull_serial or particle_cull_threaded")
		return
	_mode = "serial" if serial else "threaded"
	var threshold := int(ProjectSettings.get_setting_with_override("rendering/limits/spatial_indexer/threaded_cull_minimum_instances"))
	var expected_threshold := SERIAL_THRESHOLD if serial else THREADED_THRESHOLD
	if threshold != expected_threshold:
		_fail("project override failed for %s: threshold=%d expected=%d" % [_mode, threshold, expected_threshold])
		return

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
	_restart_particles()
	_animate(0)
	_started = true
	print("PARTICLE_CULL_ORDER start mode=%s renderer=%s driver=%s adapter=%s threshold=%d filler=%d output=%s" % [
		_mode,
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name(),
		int(ProjectSettings.get_setting_with_override("rendering/limits/spatial_indexer/threaded_cull_minimum_instances")),
		FILLER_INSTANCE_COUNT,
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

	if _capture_label >= 0:
		_poll_capture()
		return

	if _draw_label >= 0:
		_fail("render callback skipped sequence frame %d" % _draw_label)
		return

	if _resume_next_frame:
		_resume_next_frame = false
		_set_particle_speed(1.0)

	if _prewarm_frame < PREWARM_FRAMES:
		_animate(_prewarm_frame)
		_prewarm_frame += 1
		return

	if _pipeline_zero_frames < PIPELINE_QUIESCENT_FRAMES:
		var pending := RenderingServer.get_pending_pipeline_compilation_count()
		_pipeline_wait_frames += 1
		if pending == 0:
			_pipeline_zero_frames += 1
		else:
			_pipeline_zero_frames = 0
		if _pipeline_wait_frames > MAX_PIPELINE_WAIT_FRAMES:
			_fail("pipeline compilation did not become quiescent; pending=%d" % pending)
			return
		_animate(PREWARM_FRAMES + _pipeline_wait_frames)
		return

	if _prewarm_frame == PREWARM_FRAMES:
		_restart_particles()
		_animate(0)
		_prewarm_frame += 1
		_sequence_frame = 0

	_animate(_sequence_frame)
	_draw_label = _sequence_frame
	_sequence_frame += 1


func _on_frame_post_draw() -> void:
	if _draw_label < 0 or _capture_label >= 0:
		return
	var completed := _draw_label
	_draw_label = -1
	_confirmed_draws += 1
	if not CAPTURE_FRAMES.has(completed):
		return

	_capture_label = completed
	_capture_flushes = 0
	_capture_wait_frames = 0
	_capture_attempts = 0
	_main_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_alternate_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_set_particle_speed(0.0)


func _poll_capture() -> void:
	if _capture_wait_frames > 0:
		_capture_wait_frames -= 1
		return

	if _capture_flushes < 2:
		_main_viewport.get_texture().get_image()
		_alternate_viewport.get_texture().get_image()
		_capture_flushes += 1
		_capture_wait_frames = 3
		return

	var images := {
		"main": _main_viewport.get_texture().get_image(),
		"alternate": _alternate_viewport.get_texture().get_image(),
	}
	_capture_attempts += 1
	for view_name in images:
		var image: Image = images[view_name]
		if image == null or image.is_empty():
			if _capture_attempts >= 120:
				_fail("readback timed out for %s frame %d" % [view_name, _capture_label])
			return
		var foreground_pixels := _count_foreground_until(image, MIN_FOREGROUND_PIXELS)
		if foreground_pixels < MIN_FOREGROUND_PIXELS:
			_fail("%s frame %d is blank: %d foreground pixels; require %d" % [view_name, _capture_label, foreground_pixels, MIN_FOREGROUND_PIXELS])
			return

	for view_name in images:
		var image: Image = images[view_name]
		var path := "%s/%s-frame-%03d.png" % [_output, view_name, _capture_label]
		var error := image.save_png(path)
		if error != OK:
			_fail("cannot save %s: %s" % [path, error_string(error)])
			return
		var digest := FileAccess.get_sha256(path)
		_hashes[view_name][str(_capture_label)] = digest
		print("PARTICLE_CULL_ORDER view=%s frame=%03d sha256=%s" % [view_name, _capture_label, digest])

	var completed := _capture_label
	_capture_label = -1
	_main_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_alternate_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_resume_next_frame = true
	if completed == LAST_FRAME:
		if _confirmed_draws != LAST_FRAME + 1:
			_fail("confirmed draw count=%d expected=%d" % [_confirmed_draws, LAST_FRAME + 1])
			return
		if not _write_metadata():
			_begin_shutdown(2)
			return
		print("PARTICLE_CULL_ORDER_DONE mode=%s captures=%d output=%s" % [
			_mode, CAPTURE_FRAMES.size() * 2, ProjectSettings.globalize_path(_output),
		])
		_begin_shutdown(0)


func _count_foreground_until(image: Image, required: int) -> int:
	var background := image.get_pixel(0, 0)
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			var delta := absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b)
			if delta > FOREGROUND_COLOR_DELTA:
				count += 1
				if count >= required:
					return count
	return count


func _write_metadata() -> bool:
	var metadata := {
		"format": 1,
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"mode": _mode,
		"threaded_cull_threshold": int(ProjectSettings.get_setting_with_override("rendering/limits/spatial_indexer/threaded_cull_minimum_instances")),
		"filler_instance_count": FILLER_INSTANCE_COUNT,
		"viewports": ["main", "alternate"],
		"viewport_size": [VIEW_SIZE.x, VIEW_SIZE.y],
		"required_fixed_fps": FIXED_FPS,
		"prewarm_frames": PREWARM_FRAMES,
		"pipeline_wait_frames": _pipeline_wait_frames,
		"pipeline_quiescent_frames": PIPELINE_QUIESCENT_FRAMES,
		"confirmed_draws": _confirmed_draws,
		"capture_frames": CAPTURE_FRAMES,
		"seeds": SEEDS,
		"particle_amounts": [257, 96, 96],
		"coverage": [
			"view-depth sort with transparent asymmetric quads",
			"Z billboard transform alignment",
			"Z billboard Y-to-velocity transform alignment",
			"local billboard transform alignment under a rotated emitter",
			"two cameras rendering the same particle RIDs",
			"serial and worker-thread scene culling selected before renderer construction",
		],
		"sha256": _hashes,
	}
	var file := FileAccess.open("%s/metadata.json" % _output, FileAccess.WRITE)
	if file == null:
		push_error("PARTICLE_CULL_ORDER cannot write metadata: %s" % FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(metadata, "\t") + "\n")
	var error := file.get_error()
	if error != OK:
		push_error("PARTICLE_CULL_ORDER metadata write failed: %s" % error_string(error))
		return false
	return true


func _fail(message: String) -> void:
	push_error("PARTICLE_CULL_ORDER %s" % message)
	_begin_shutdown(2)


func _begin_shutdown(exit_code: int) -> void:
	_started = false
	_shutdown_exit_code = exit_code
	_shutdown_frames = 2
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	if _main_viewport != null:
		_main_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _alternate_viewport != null:
		_alternate_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _build_fixture() -> void:
	_main_viewport = _make_viewport("MainViewport")
	_main_viewport.own_world_3d = true
	add_child(_main_viewport)

	var world := Node3D.new()
	world.name = "ParticleWorld"
	_main_viewport.add_child(world)
	_add_environment(world)

	_main_camera = _make_camera("MainCamera")
	_main_viewport.add_child(_main_camera)

	_alternate_viewport = _make_viewport("AlternateViewport")
	_alternate_viewport.world_3d = _main_viewport.find_world_3d()
	add_child(_alternate_viewport)
	assert(_alternate_viewport.find_world_3d() == _main_viewport.find_world_3d())
	_alternate_camera = _make_camera("AlternateCamera")
	_alternate_viewport.add_child(_alternate_camera)

	_add_preview(_main_viewport, 0)
	_add_preview(_alternate_viewport, VIEW_SIZE.x)

	var arrow_texture := _make_arrow_texture()
	var depth := _make_particles("DepthZBillboard", 257, SEEDS["depth"], GPUParticles3D.DRAW_ORDER_VIEW_DEPTH, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD, 0.0, arrow_texture)
	depth.position = Vector3(-3.0, 0.0, 0.0)
	world.add_child(depth)
	_particles.append(depth)

	var billboard := _make_particles("VelocityBillboard", 96, SEEDS["billboard"], GPUParticles3D.DRAW_ORDER_INDEX, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY, 1.0, arrow_texture)
	billboard.position = Vector3(0.0, 0.0, 0.0)
	world.add_child(billboard)
	_particles.append(billboard)

	var local := _make_particles("LocalBillboard", 96, SEEDS["local"], GPUParticles3D.DRAW_ORDER_VIEW_DEPTH, GPUParticles3D.TRANSFORM_ALIGN_LOCAL_BILLBOARD, 2.0, arrow_texture)
	local.position = Vector3(3.0, 0.0, 0.0)
	local.rotation = Vector3(0.31, -0.57, 0.23)
	world.add_child(local)
	_particles.append(local)

	_add_cull_fillers(world)


func _make_viewport(view_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = view_name
	viewport.size = VIEW_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = false
	return viewport


func _make_camera(camera_name: String) -> Camera3D:
	var camera := Camera3D.new()
	camera.name = camera_name
	camera.current = true
	camera.fov = 48.0
	camera.near = 0.1
	camera.far = 80.0
	return camera


func _add_preview(viewport: SubViewport, offset_x: int) -> void:
	var preview := TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.position = Vector2(offset_x, 0)
	preview.size = Vector2(VIEW_SIZE)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(preview)


func _add_environment(world: Node3D) -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("101321")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("ffffff")
	environment.ambient_light_energy = 0.2
	environment_node.environment = environment
	world.add_child(environment_node)


func _make_particles(particle_name: String, amount: int, seed: int, draw_order: int, transform_align: int, system_offset: float, texture: Texture2D) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = particle_name
	particles.emitting = false
	particles.amount = amount
	particles.lifetime = 10.0
	particles.one_shot = false
	particles.explosiveness = 1.0
	particles.randomness = 0.0
	particles.fixed_fps = FIXED_FPS
	particles.interpolate = false
	particles.fract_delta = false
	particles.local_coords = true
	particles.draw_order = draw_order
	particles.transform_align = transform_align
	particles.visibility_aabb = AABB(Vector3(-5, -5, -5), Vector3(10, 10, 10))
	particles.use_fixed_seed = true
	particles.seed = seed

	var process_shader := Shader.new()
	process_shader.code = PARTICLE_SHADER
	var process_material := ShaderMaterial.new()
	process_material.shader = process_shader
	process_material.set_shader_parameter("system_offset", system_offset)
	particles.process_material = process_material

	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.46, 0.28)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mesh.material = material
	particles.draw_pass_1 = mesh
	return particles


func _make_arrow_texture() -> ImageTexture:
	var image := Image.create_empty(32, 20, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	for y in range(20):
		for x in range(32):
			var shaft := x >= 3 and x <= 22 and y >= 7 and y <= 12
			var head: bool = x >= 18 and x <= 29 and absf(float(y) - 9.5) <= float(29 - x) * 0.62
			var fin := x >= 5 and x <= 11 and y >= 3 and y <= 7
			if shaft or head or fin:
				var color := Color(1.0, 0.9, 0.2, 1.0) if y < 10 else Color(0.15, 0.85, 1.0, 1.0)
				if fin:
					color = Color(1.0, 0.2, 0.55, 1.0)
				image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


func _add_cull_fillers(world: Node3D) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.02, 0.02, 0.02)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.BLACK
	mesh.material = material
	for index in range(FILLER_INSTANCE_COUNT):
		var filler := MeshInstance3D.new()
		filler.name = "CullFiller%03d" % index
		filler.mesh = mesh
		filler.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		filler.position = Vector3(500.0 + float(index % 32), 500.0 + float(index / 32), 500.0)
		world.add_child(filler)


func _restart_particles() -> void:
	for particles in _particles:
		particles.restart(true)
	_set_particle_speed(1.0)


func _set_particle_speed(value: float) -> void:
	for particles in _particles:
		particles.speed_scale = value


func _animate(frame: int) -> void:
	var phase := frame % 4
	var main_positions := [
		Vector3(0.0, 1.2, 13.0),
		Vector3(8.0, 2.1, 9.0),
		Vector3(-8.5, -0.6, 8.5),
		Vector3(2.0, 7.0, 10.0),
	]
	var alternate_positions := [
		Vector3(-9.5, 2.8, 6.5),
		Vector3(1.0, -6.0, 11.0),
		Vector3(10.0, 1.0, 6.0),
		Vector3(-2.0, 7.5, 9.0),
	]
	_main_camera.look_at_from_position(main_positions[phase], Vector3.ZERO, Vector3.UP)
	_alternate_camera.look_at_from_position(alternate_positions[phase], Vector3.ZERO, Vector3.UP)
