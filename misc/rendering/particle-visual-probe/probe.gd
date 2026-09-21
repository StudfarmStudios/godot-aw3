extends Node

# This is deliberately a procedural scene: it has no imported assets and no TIME
# shader inputs. The same command can therefore compare two engine binaries on the
# same GPU without import state or wall-clock time entering the result.

const VIEW_SIZE := Vector2i(640, 480)
const FIXED_FPS := 60
const PREWARM_FRAMES := 90
const LAST_FRAME := 119
const CAPTURE_FRAMES := [0, 1, 2, 8, 16, 30, 45, 60, 90, 119]
const MIN_FOREGROUND_PIXELS := 64
const FOREGROUND_COLOR_DELTA := 0.04
const SEEDS := {
	"depth": 0x13579BDF,
	"collision_parent": 0x2468ACE0,
	"collision_child": 0x10203040,
	"trail": 0x55667788,
	"canvas": 0x0BADF00D,
}

var _viewport: SubViewport
var _camera: Camera3D
var _depth_particles: GPUParticles3D
var _collision_parent: GPUParticles3D
var _collision_child: GPUParticles3D
var _trail_particles: GPUParticles3D
var _canvas_particles: GPUParticles2D
var _particles: Array[Node] = []

var _output := "user://particle-visual-probe"
var _no_taa := false
var _started := false
var _shutdown_frames := -1
var _shutdown_exit_code := 0
var _prewarm_frame := 0
var _sequence_frame := 0
var _draw_label := -1
var _capture_label := -1
var _capture_flushes := 0
var _capture_wait_frames := 0
var _capture_attempts := 0
var _resume_next_frame := false
var _hashes := {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")
		elif arg == "--no-taa":
			_no_taa = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output))
	_build_fixture()
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	call_deferred("_start_probe")


func _start_probe() -> void:
	_restart_particles()
	_animate(0)
	_started = true
	print("PARTICLE_VISUAL start renderer=%s driver=%s adapter=%s prewarm=%d captures=%s no_taa=%s output=%s" % [
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name(),
		PREWARM_FRAMES,
		CAPTURE_FRAMES,
		_no_taa,
		ProjectSettings.globalize_path(_output),
	])


func _process(_delta: float) -> void:
	if _shutdown_frames >= 0:
		if _shutdown_frames == 0:
			get_tree().quit(_shutdown_exit_code)
		else:
			_shutdown_frames -= 1
		return
	if not _started:
		return

	if _capture_label >= 0:
		_poll_capture()
		return

	if _resume_next_frame:
		_resume_next_frame = false
		_set_particle_speed(1.0)

	if _prewarm_frame < PREWARM_FRAMES:
		_animate(_prewarm_frame)
		_draw_label = -1
		_prewarm_frame += 1
		return

	if _prewarm_frame == PREWARM_FRAMES:
		# All enabled particle, trail, sub-emitter, collision, sort, TAA, and 2D draw
		# pipelines have had 90 visible frames to compile. Restart after that
		# warm-up so pending asynchronous WebGPU pipelines cannot skip an event.
		_restart_particles()
		_animate(0)
		_prewarm_frame += 1
		_sequence_frame = 0

	_animate(_sequence_frame)
	_draw_label = _sequence_frame
	_sequence_frame += 1


func _on_frame_post_draw() -> void:
	if _capture_label >= 0 or not CAPTURE_FRAMES.has(_draw_label):
		return
	_capture_label = _draw_label
	_draw_label = -1
	_capture_flushes = 0
	_capture_wait_frames = 0
	_capture_attempts = 0
	# Preserve the exact requested render while WebGPU completes an asynchronous
	# texture transfer. Simulation is also frozen, so the retry frames do not
	# consume particle fixed steps. Disabling viewport updates keeps TAA history
	# and jitter from changing the image while stale readbacks are drained.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_set_particle_speed(0.0)


func _poll_capture() -> void:
	if _capture_wait_frames > 0:
		_capture_wait_frames -= 1
		return

	# Match the native WebGPU readback probes: discard two possibly stale
	# transfers, allowing three engine frames for each to complete. Since the
	# SubViewport is disabled, every transfer still refers to the target image.
	if _capture_flushes < 2:
		_viewport.get_texture().get_image()
		_capture_flushes += 1
		_capture_wait_frames = 3
		return

	var image := _viewport.get_texture().get_image()
	_capture_attempts += 1
	if image == null or image.is_empty():
		if _capture_attempts >= 120:
			push_error("PARTICLE_VISUAL readback timed out for frame %d" % _capture_label)
			_begin_shutdown(2)
		return

	var foreground_pixels := _count_foreground_until(image, MIN_FOREGROUND_PIXELS)
	if foreground_pixels < MIN_FOREGROUND_PIXELS:
		push_error("PARTICLE_VISUAL frame %d is blank: only %d pixels differ from the corner background; require at least %d" % [
			_capture_label, foreground_pixels, MIN_FOREGROUND_PIXELS,
		])
		_begin_shutdown(2)
		return

	var path := "%s/frame-%03d.png" % [_output, _capture_label]
	var error := image.save_png(path)
	if error != OK:
		push_error("PARTICLE_VISUAL cannot save %s: %s" % [path, error_string(error)])
		_begin_shutdown(2)
		return
	var digest := FileAccess.get_sha256(path)
	_hashes[str(_capture_label)] = digest
	print("PARTICLE_VISUAL frame=%03d sha256=%s" % [_capture_label, digest])
	var completed := _capture_label
	_capture_label = -1
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Keep speed zero for this transition frame. On the next process frame the
	# next numbered simulation step and speed restoration happen together.
	_resume_next_frame = true
	if completed == LAST_FRAME:
		if not _write_metadata():
			_begin_shutdown(2)
			return
		print("PARTICLE_VISUAL_DONE frames=%d output=%s" % [_hashes.size(), ProjectSettings.globalize_path(_output)])
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
	var coverage := [
		"3D view-depth sorting (1025 particles)",
		"3D rigid particle collision",
		"3D ribbon trails",
		"2D particle simulation and instance copy",
	]
	var skipped_coverage: Array[String] = []
	if _no_taa:
		skipped_coverage.append("TAA")
		skipped_coverage.append("3D index-order particle motion vectors with moving camera/emitter")
	else:
		coverage.append("TAA")
		coverage.append("3D index-order particle motion vectors with moving camera/emitter")
	coverage.append("3D collision-triggered sub-emitter")
	var metadata := {
		"format": 1,
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"viewport": [VIEW_SIZE.x, VIEW_SIZE.y],
		"required_fixed_fps": FIXED_FPS,
		"prewarm_frames": PREWARM_FRAMES,
		"capture_frames": CAPTURE_FRAMES,
		"seeds": SEEDS,
		"taa": not _no_taa,
		"no_taa": _no_taa,
		"coverage": coverage,
		"skipped_coverage": skipped_coverage,
		"sha256": _hashes,
	}
	var file := FileAccess.open("%s/metadata.json" % _output, FileAccess.WRITE)
	if file == null:
		push_error("PARTICLE_VISUAL cannot write metadata: %s" % FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(metadata, "\t") + "\n")
	var error := file.get_error()
	if error != OK:
		push_error("PARTICLE_VISUAL cannot write metadata: %s" % error_string(error))
		return false
	return true


func _begin_shutdown(exit_code: int) -> void:
	_started = false
	_shutdown_exit_code = exit_code
	_shutdown_frames = 2
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	for child in get_children():
		child.queue_free()


func _build_fixture() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "FixtureViewport"
	_viewport.size = VIEW_SIZE
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.use_taa = not _no_taa
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	add_child(_viewport)

	var preview := TextureRect.new()
	preview.texture = _viewport.get_texture()
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(preview)

	var world := Node3D.new()
	world.name = "ParticleWorld"
	_viewport.add_child(world)

	var environment := WorldEnvironment.new()
	var environment_resource := Environment.new()
	environment_resource.background_mode = Environment.BG_COLOR
	environment_resource.background_color = Color("101321")
	environment_resource.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment_resource.ambient_light_color = Color("8296c7")
	environment_resource.ambient_light_energy = 0.35
	environment.environment = environment_resource
	world.add_child(environment)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 52.0
	_camera.near = 0.1
	_camera.far = 50.0
	world.add_child(_camera)

	_depth_particles = _make_depth_particles()
	world.add_child(_depth_particles)

	_collision_parent = _make_collision_subemitter()
	world.add_child(_collision_parent)

	var collider := GPUParticlesCollisionBox3D.new()
	collider.name = "CollisionFloor"
	collider.position = Vector3(0, -2.25, 0)
	collider.size = Vector3(4.8, 0.25, 3.0)
	world.add_child(collider)
	world.add_child(_make_floor_mesh())

	_trail_particles = _make_trail_particles()
	world.add_child(_trail_particles)

	_canvas_particles = _make_canvas_particles()
	_viewport.add_child(_canvas_particles)

	_particles.append(_depth_particles)
	_particles.append(_collision_child)
	_particles.append(_collision_parent)
	_particles.append(_trail_particles)
	_particles.append(_canvas_particles)


func _make_depth_particles() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "DepthSorted1025"
	particles.position = Vector3(-3.2, 0.2, 0)
	particles.emitting = false
	particles.amount = 1025
	particles.lifetime = 2.4
	particles.randomness = 0.2
	particles.fixed_fps = FIXED_FPS
	particles.interpolate = true
	particles.fract_delta = true
	particles.local_coords = true
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	particles.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	particles.use_fixed_seed = true
	particles.seed = SEEDS.depth

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(1.7, 2.3, 2.7)
	process.direction = Vector3(0.15, 0.25, 0)
	process.spread = 180.0
	process.initial_velocity_min = 0.15
	process.initial_velocity_max = 0.65
	process.gravity = Vector3.ZERO
	process.scale_min = 0.15
	process.scale_max = 0.34
	process.color_initial_ramp = _gradient_texture([
		Color(0.2, 0.75, 1.0, 0.22), Color(1.0, 0.25, 0.75, 0.28), Color(1.0, 0.78, 0.2, 0.24)
	])
	particles.process_material = process
	particles.draw_pass_1 = _quad_mesh(Vector2(0.72, 0.72), Color.WHITE, false)
	return particles


func _make_collision_subemitter() -> GPUParticles3D:
	var parent := GPUParticles3D.new()
	parent.name = "CollisionParent"
	parent.position = Vector3(0, 1.9, 0)
	parent.emitting = false
	parent.amount = 32
	parent.lifetime = 2.2
	parent.one_shot = true
	parent.explosiveness = 1.0
	parent.fixed_fps = FIXED_FPS
	parent.interpolate = true
	parent.local_coords = false
	parent.visibility_aabb = AABB(Vector3(-4, -6, -3), Vector3(8, 10, 6))
	parent.use_fixed_seed = true
	parent.seed = SEEDS.collision_parent

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.45
	process.direction = Vector3(0, -1, 0)
	process.spread = 24.0
	process.initial_velocity_min = 2.5
	process.initial_velocity_max = 4.5
	process.gravity = Vector3(0, -7.0, 0)
	process.scale_min = 0.18
	process.scale_max = 0.3
	process.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	process.collision_bounce = 0.65
	process.collision_friction = 0.1
	process.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_COLLISION
	process.sub_emitter_amount_at_collision = 3
	process.sub_emitter_keep_velocity = true
	process.color = Color(1.0, 0.55, 0.12, 1.0)
	parent.process_material = process
	parent.draw_pass_1 = _quad_mesh(Vector2(0.34, 0.34), Color(1.0, 0.65, 0.22, 0.92), true)

	_collision_child = GPUParticles3D.new()
	_collision_child.name = "CollisionSparks"
	_collision_child.emitting = false
	_collision_child.amount = 256
	_collision_child.lifetime = 0.7
	_collision_child.fixed_fps = FIXED_FPS
	_collision_child.interpolate = true
	_collision_child.local_coords = false
	_collision_child.visibility_aabb = AABB(Vector3(-5, -7, -4), Vector3(10, 12, 8))
	_collision_child.use_fixed_seed = true
	_collision_child.seed = SEEDS.collision_child
	var child_process := ParticleProcessMaterial.new()
	child_process.direction = Vector3(0, 1, 0)
	child_process.spread = 180.0
	child_process.initial_velocity_min = 1.5
	child_process.initial_velocity_max = 4.0
	child_process.gravity = Vector3(0, -4.0, 0)
	child_process.scale_min = 0.07
	child_process.scale_max = 0.16
	child_process.color = Color(0.25, 0.85, 1.0, 1.0)
	_collision_child.process_material = child_process
	_collision_child.draw_pass_1 = _quad_mesh(Vector2(0.2, 0.2), Color(0.35, 0.9, 1.0, 0.9), true)
	parent.add_child(_collision_child)
	parent.sub_emitter = NodePath("CollisionSparks")
	return parent


func _make_trail_particles() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "RibbonTrails"
	particles.position = Vector3(3.1, 0.1, 0)
	particles.emitting = false
	particles.amount = 40
	particles.lifetime = 1.4
	particles.randomness = 0.15
	particles.fixed_fps = FIXED_FPS
	particles.interpolate = true
	particles.local_coords = true
	particles.trail_enabled = true
	particles.trail_lifetime = 0.55
	particles.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	particles.visibility_aabb = AABB(Vector3(-4, -4, -3), Vector3(8, 8, 6))
	particles.use_fixed_seed = true
	particles.seed = SEEDS.trail

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.35
	process.direction = Vector3(0.3, 1.0, 0)
	process.spread = 45.0
	process.initial_velocity_min = 1.4
	process.initial_velocity_max = 3.2
	process.gravity = Vector3(-0.9, -0.8, 0)
	process.scale_min = 0.45
	process.scale_max = 0.8
	process.color_initial_ramp = _gradient_texture([
		Color(0.35, 1.0, 0.5, 0.9), Color(0.1, 0.55, 1.0, 0.75)
	])
	particles.process_material = process

	var trail := RibbonTrailMesh.new()
	trail.shape = RibbonTrailMesh.SHAPE_CROSS
	trail.size = 0.14
	trail.sections = 8
	trail.section_length = 0.09
	trail.section_segments = 2
	var width := Curve.new()
	width.add_point(Vector2(0, 0.0))
	width.add_point(Vector2(0.12, 1.0))
	width.add_point(Vector2(1, 0.0))
	trail.curve = width
	trail.material = _particle_material(Color(0.4, 1.0, 0.55, 0.88), true, false)
	particles.draw_pass_1 = trail
	return particles


func _make_canvas_particles() -> GPUParticles2D:
	var particles := GPUParticles2D.new()
	particles.name = "CanvasParticles"
	particles.position = Vector2(548, 400)
	particles.emitting = false
	particles.amount = 128
	particles.lifetime = 1.25
	particles.randomness = 0.2
	particles.fixed_fps = FIXED_FPS
	particles.interpolate = true
	particles.local_coords = true
	particles.visibility_rect = Rect2(-110, -110, 220, 220)
	particles.use_fixed_seed = true
	particles.seed = SEEDS.canvas
	particles.texture = _circle_texture()

	var process := ParticleProcessMaterial.new()
	process.particle_flag_disable_z = true
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 4.0
	process.direction = Vector3(0, -1, 0)
	process.spread = 180.0
	process.initial_velocity_min = 22.0
	process.initial_velocity_max = 68.0
	process.gravity = Vector3(0, 35, 0)
	process.scale_min = 0.35
	process.scale_max = 0.9
	process.color_initial_ramp = _gradient_texture([
		Color(1.0, 0.25, 0.7, 0.9), Color(0.25, 0.8, 1.0, 0.75), Color(1.0, 0.8, 0.25, 0.0)
	])
	particles.process_material = process
	return particles


func _make_floor_mesh() -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = "CollisionFloorGuide"
	instance.position = Vector3(0, -2.25, 0.15)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(4.8, 0.08, 0.08)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.38, 0.55, 0.7)
	mesh.material = material
	instance.mesh = mesh
	return instance


func _quad_mesh(size: Vector2, color: Color, additive: bool) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = size
	mesh.material = _particle_material(color, additive, true)
	return mesh


func _particle_material(color: Color, additive: bool, billboard: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = color
	material.no_depth_test = false
	if additive:
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	if billboard:
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	return material


func _gradient_texture(colors: Array[Color]) -> GradientTexture1D:
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	for index in range(colors.size()):
		offsets.append(float(index) / float(maxi(colors.size() - 1, 1)))
	gradient.offsets = offsets
	gradient.colors = PackedColorArray(colors)
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	texture.use_hdr = true
	return texture


func _circle_texture() -> ImageTexture:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	for y in range(16):
		for x in range(16):
			var distance := Vector2(x - 7.5, y - 7.5).length() / 7.5
			var alpha := clampf(1.0 - distance, 0.0, 1.0)
			image.set_pixel(x, y, Color(1, 1, 1, alpha * alpha))
	return ImageTexture.create_from_image(image)


func _restart_particles() -> void:
	# Clear the receiver before the parent. restart(true) is essential: the
	# default restart path randomizes the seed when use_fixed_seed is false.
	_collision_child.restart(true)
	_collision_child.emitting = false
	_depth_particles.restart(true)
	_collision_parent.restart(true)
	_trail_particles.restart(true)
	_canvas_particles.restart(true)
	_set_particle_speed(1.0)


func _set_particle_speed(value: float) -> void:
	for particle in _particles:
		particle.speed_scale = value


func _animate(frame: int) -> void:
	var t := float(frame) / float(FIXED_FPS)
	# Camera translation and rotation make TAA request particle motion vectors.
	_camera.position = Vector3(0.32 * sin(t * 1.7), 0.2 * cos(t * 1.3), 16.0)
	_camera.rotation = Vector3(0.012 * sin(t * 1.1), 0.025 * sin(t * 1.5), 0)
	# A local-coordinate index-order system distinguishes object motion from its
	# internal particle velocity in the motion-vector instance copy.
	_trail_particles.position = Vector3(3.1 + 0.45 * sin(t * 2.0), 0.1 + 0.35 * cos(t * 1.4), 0)
	_canvas_particles.position = Vector2(548 + 15 * sin(t * 2.2), 400 + 10 * cos(t * 1.6))
