extends SceneTree

const VIEW_SIZE := Vector2i(1280, 720)
const FIXED_FPS := 60
const EMITTER_COUNT := 200
const SLOT_COUNT := 256
const AMOUNT_RATIO := 0.02
const LIFETIME := 0.2
const PARTICLE_FIXED_FPS := 100
const PARTICLE_SPEED := 2.0
const WARMUP_FRAMES := 30
const PIPELINE_ZERO_FRAMES := 3
const PIPELINE_WAIT_LIMIT := 600
const LAST_FRAME := 119
const BASE_SEED := 0x51A70000

var output_path := "user://particle-frame-order-probe"
var viewport: SubViewport
var particles: Array[GPUParticles3D] = []
var saved_time_scale := 1.0
var pipeline_wait_frames := 0
var pipeline_pending_peak := 0


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
	output_path = ProjectSettings.globalize_path(output_path)
	saved_time_scale = Engine.time_scale
	Engine.time_scale = 0.0
	call_deferred("_run")


func _run() -> void:
	if DirAccess.make_dir_recursive_absolute(output_path) != OK:
		await _finish(2, "Cannot create output directory: %s" % output_path)
		return
	_build_fixture()
	if not await _warm_and_drain_pipelines():
		await _finish(2, "Pipeline compilation did not quiesce")
		return

	_reset_particles()
	Engine.time_scale = saved_time_scale

	# The measured timeline is intentionally uninterrupted. No readback, viewport
	# pause, speed change, or explicit process request occurs before frame 119.
	for frame in range(LAST_FRAME + 1):
		await RenderingServer.frame_post_draw

	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		await _finish(2, "Frame 119 readback is empty")
		return
	var foreground_pixels := _count_foreground(image)
	if foreground_pixels < 64:
		await _finish(2, "Frame 119 has insufficient foreground: %d pixels" % foreground_pixels)
		return

	var image_path := output_path.path_join("frame-119.png")
	var save_error := image.save_png(image_path)
	if save_error != OK:
		await _finish(2, "Cannot save frame-119.png: %s" % error_string(save_error))
		return

	# capture_aabb() performs a GPU readback. Keep all 200 calls after the only
	# visual capture so they cannot repair or perturb the dependency under test.
	var aabb_rows := PackedStringArray()
	for index in range(particles.size()):
		var box := particles[index].capture_aabb()
		aabb_rows.append("%03d %s %s %s %s %s %s" % [
			index, String.num(box.position.x, 9), String.num(box.position.y, 9), String.num(box.position.z, 9),
			String.num(box.size.x, 9), String.num(box.size.y, 9), String.num(box.size.z, 9),
		])
	var aabb_digest := "\n".join(aabb_rows).sha256_text()

	if not _write_metadata(image_path, foreground_pixels, aabb_digest):
		await _finish(2, "Cannot write metadata.json")
		return
	print("PARTICLE_FRAME_ORDER_DONE image=%s aabb=%s foreground=%d" % [
		FileAccess.get_sha256(image_path), aabb_digest, foreground_pixels,
	])
	await _finish(0, "")


func _build_fixture() -> void:
	# Match the AW3 harness's tiny off-screen presentation window. The measured
	# particles render into the fixed-size SubViewport below.
	root.size = Vector2i(32, 32)
	root.position = Vector2i(-4096, -4096)
	viewport = SubViewport.new()
	viewport.name = "ParticleFrameOrderViewport"
	viewport.size = VIEW_SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	root.add_child(viewport)

	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.008, 0.01, 0.02, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.32, 0.25, 0.42, 1.0)
	environment.ambient_light_energy = 0.5
	environment_node.environment = environment
	viewport.add_child(environment_node)

	var camera := Camera3D.new()
	camera.current = true
	camera.fov = 70.0
	camera.position = Vector3(0, 0, 800)
	camera.near = 0.1
	camera.far = 10000.0
	viewport.add_child(camera)

	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape_scale = Vector3(0, 1, 1)
	process_material.angle_min = 0.000010728835
	process_material.angle_max = 0.000010728835
	process_material.direction = Vector3.ZERO
	process_material.spread = 1.0
	process_material.initial_velocity_min = 30.0
	process_material.initial_velocity_max = 60.0
	process_material.gravity = Vector3.ZERO
	process_material.scale_min = 0.0
	process_material.scale_max = 1.0
	process_material.hue_variation_min = 0.99999994
	process_material.hue_variation_max = 0.99999994
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0, 1))
	scale_curve.add_point(Vector2(0.13963965, 1))
	scale_curve.add_point(Vector2(1, 0))
	scale_curve.set_point_right_tangent(1, -0.056690183)
	var scale_texture := CurveTexture.new()
	scale_texture.curve = scale_curve
	process_material.scale_curve = scale_texture
	process_material.color_ramp = GradientTexture1D.new()
	process_material.turbulence_enabled = true
	process_material.turbulence_noise_strength = 0.2
	process_material.turbulence_noise_scale = 0.1
	process_material.turbulence_noise_speed = Vector3.ZERO
	process_material.turbulence_noise_speed_random = 0.1
	process_material.turbulence_influence_min = 0.1
	process_material.turbulence_influence_max = 0.2

	var flame_texture := _make_flame_texture()
	var quads: Array[QuadMesh] = []
	for unused in range(4):
		var draw_material := StandardMaterial3D.new()
		draw_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		draw_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		draw_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		draw_material.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		draw_material.specular_mode = BaseMaterial3D.SPECULAR_TOON
		draw_material.disable_fog = true
		draw_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		draw_material.billboard_keep_scale = true
		draw_material.grow_amount = 4.444
		draw_material.distance_fade_max_distance = 5.0
		draw_material.metallic_specular = 0.2
		draw_material.disable_receive_shadows = true
		draw_material.stencil_flags = BaseMaterial3D.STENCIL_FLAG_WRITE
		draw_material.albedo_texture = flame_texture
		var quad := QuadMesh.new()
		quad.size = Vector2(10, 10)
		quad.material = draw_material
		quads.append(quad)

	for index in range(EMITTER_COUNT):
		var ship_index := int(index / 4)
		var nozzle := index % 4
		var particle := GPUParticles3D.new()
		particle.name = "Emitter%03d" % index
		particle.position = _ship_grid_position(ship_index) + Vector3(
			-25.459488,
			[7.6036305, 3.10751, -3.0396762, -7.6674585][nozzle],
			4.294133 + [-1.1923246, -0.68152714, -0.68152714, -1.1923246][nozzle]
		)
		particle.rotation.y = PI * 0.5
		# Match the authored scene state. The AW3 harness applies its forward-idle
		# amount ratio and velocity override only after every instance exists.
		particle.emitting = false
		particle.amount = SLOT_COUNT
		particle.amount_ratio = 0.0
		particle.lifetime = LIFETIME
		particle.speed_scale = PARTICLE_SPEED
		particle.fixed_fps = PARTICLE_FIXED_FPS
		particle.local_coords = false
		particle.collision_base_size = 0.0
		particle.trail_lifetime = 3.0
		particle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		particle.use_fixed_seed = true
		particle.seed = BASE_SEED + index
		particle.visibility_aabb = AABB(Vector3.ZERO, Vector3.ONE)
		particle.custom_aabb = AABB(Vector3(-14, -14, -14), Vector3(28, 28, 54))
		particle.process_material = process_material
		particle.draw_pass_1 = quads[nozzle]
		viewport.add_child(particle)
		particles.append(particle)

	for particle in particles:
		particle.amount_ratio = AMOUNT_RATIO
		particle.emitting = true
		# Deliberately repeat this shared-resource update just as the AW3 harness
		# does while visiting each emitter.
		process_material.initial_velocity_min = 10.0
		process_material.initial_velocity_max = 20.0


func _ship_grid_position(index: int) -> Vector3:
	var columns := 8
	var rows := 7
	var row := int(index / columns)
	return Vector3((index % columns - 3.5) * 115.0, (float(rows - 1) * 0.5 - row) * 75.0, 0)


func _make_flame_texture() -> ImageTexture:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in range(32):
		for x in range(32):
			var distance := Vector2(x - 15.5, y - 15.5).length() / 15.5
			var alpha := clampf(1.0 - distance, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 0.42, 0.06, alpha * alpha))
	return ImageTexture.create_from_image(image)


func _warm_and_drain_pipelines() -> bool:
	_reset_particles()
	for unused in range(WARMUP_FRAMES):
		for particle in particles:
			particle.request_particles_process(1.0 / FIXED_FPS)
		await RenderingServer.frame_post_draw

	var consecutive_zero := 0
	for frame in range(PIPELINE_WAIT_LIMIT):
		await RenderingServer.frame_post_draw
		pipeline_wait_frames = frame + 1
		var pending := RenderingServer.get_pending_pipeline_compilation_count()
		pipeline_pending_peak = maxi(pipeline_pending_peak, pending)
		if pending == 0:
			consecutive_zero += 1
			if consecutive_zero >= PIPELINE_ZERO_FRAMES:
				return true
		else:
			consecutive_zero = 0
	return false


func _reset_particles() -> void:
	# Match the AW3 harness command sequence: clear and stop every system, then
	# restart each top-level emitter. This probe has no sub-emitter targets.
	for particle in particles:
		particle.restart(true)
		particle.emitting = false
	for particle in particles:
		particle.restart(true)


func _count_foreground(image: Image) -> int:
	var background := image.get_pixel(0, 0)
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			if absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b) > 0.04:
				count += 1
	return count


func _write_metadata(image_path: String, foreground_pixels: int, aabb_digest: String) -> bool:
	var seeds := PackedInt64Array()
	for index in range(EMITTER_COUNT):
		seeds.append(BASE_SEED + index)
	var metadata := {
		"format": 1,
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"required_fixed_fps": FIXED_FPS,
		"viewport": [VIEW_SIZE.x, VIEW_SIZE.y],
		"warmup": {"frames": WARMUP_FRAMES, "pending_wait_frames": pipeline_wait_frames, "pending_peak": pipeline_pending_peak},
		"timeline": {"first_frame": 0, "last_frame": LAST_FRAME, "intermediate_readbacks": 0, "capture_frames": [LAST_FRAME]},
		"particles": {"emitters": EMITTER_COUNT, "ships": 50, "emitters_per_ship": 4, "slots": SLOT_COUNT, "amount_ratio": AMOUNT_RATIO, "lifetime": LIFETIME, "speed_scale": PARTICLE_SPEED, "fixed_fps": PARTICLE_FIXED_FPS, "local_coords": false, "shared_process_material": true},
		"turbulence": {"enabled": true, "strength": 0.2, "scale": 0.1, "influence_min": 0.1, "influence_max": 0.2},
		"seeds": seeds,
		"frame_119_sha256": FileAccess.get_sha256(image_path),
		"frame_119_foreground_pixels": foreground_pixels,
		"aabb_after_frame_119_sha256": aabb_digest,
	}
	var file := FileAccess.open(output_path.path_join("metadata.json"), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(metadata, "\t") + "\n")
	return file.get_error() == OK


func _finish(exit_code: int, message: String) -> void:
	if not message.is_empty():
		push_error("PARTICLE_FRAME_ORDER: %s" % message)
	Engine.time_scale = saved_time_scale
	if viewport != null:
		for particle in particles:
			particle.process_material = null
			particle.draw_pass_1 = null
			particle.free()
		particles.clear()
		viewport.free()
		viewport = null
		for unused in range(4):
			await process_frame
		RenderingServer.force_sync()
		for unused in range(2):
			await process_frame
	quit(exit_code)
