extends Node

const Probe = preload("res://probe.gd")
var viewport: SubViewport
var probe: CompositorEffect
var environment: Environment
var floor_material: StandardMaterial3D
var passed := 0
var failed := 0
var output := ""
var half_size := true
var use_msaa := false
var debug_buffers := false

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument == "--full-size":
			half_size = false
		elif argument == "--debug-buffers":
			debug_buffers = true
		elif argument == "--msaa":
			use_msaa = true
	RenderingServer.environment_set_ssr_half_size(half_size)
	RenderingServer.render_loop_enabled = false
	viewport = SubViewport.new()
	viewport.size = Vector2i(192, 144)
	viewport.msaa_3d = Viewport.MSAA_4X if use_msaa else Viewport.MSAA_DISABLED
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 2.6, 6.0)
	viewport.add_child(camera)
	camera.look_at(Vector3(0.0, 0.2, 0.0))
	camera.current = true
	var world := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.015, 0.015, 0.015)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.2
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.ssr_max_steps = 128
	world.environment = environment
	probe = Probe.new()
	probe.debug_buffers = debug_buffers
	world.compositor = Compositor.new()
	world.compositor.compositor_effects = [probe]
	viewport.add_child(world)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(12, 12)
	floor_material = StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.7, 0.7, 0.7)
	floor_material.metallic = 0.9
	floor_material.roughness = 0.12
	_mesh(floor_mesh, floor_material, Vector3(0, -0.6, 0))
	var cube := BoxMesh.new()
	cube.size = Vector3(1.4, 1.4, 1.4)
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(1.0, 0.015, 0.01)
	red.emission_enabled = true
	red.emission = Color(1.0, 0.0, 0.0)
	red.emission_energy_multiplier = 2.0
	_mesh(cube, red, Vector3(0.0, 0.2, 0.0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -25, 0)
	light.light_energy = 1.2
	viewport.add_child(light)
	for phase: Array in [["sharp", Vector2i(192, 144), 0.12], ["rough", Vector2i(192, 144), 0.55], ["odd_width", Vector2i(193, 144), 0.12], ["odd_height", Vector2i(192, 137), 0.12], ["odd_both", Vector2i(193, 137), 0.12]]:
		viewport.size = phase[1]
		floor_material.roughness = phase[2]
		environment.ssr_enabled = false
		await _wait_for_pipelines()
		await _frames(4)
		var disabled := viewport.get_texture().get_image()
		environment.ssr_enabled = true
		await _wait_for_pipelines()
		await _frames(8)
		var enabled := viewport.get_texture().get_image()
		if debug_buffers and not output.is_empty():
			probe.capture_path = output.path_join(phase[0])
			await _frames(1)
		var source_pixels := 0
		var reflected_pixels := 0
		var reflection_sum := 0.0
		for y in viewport.size.y:
			for x in viewport.size.x:
				var a := disabled.get_pixel(x, y)
				var b := enabled.get_pixel(x, y)
				if a.r > 0.65 and a.r > a.g * 3.0:
					source_pixels += 1
				if y > viewport.size.y * 0.55:
					var delta := b.r - a.r
					if delta > 0.025 and b.r > b.g * 1.15:
						reflected_pixels += 1
						reflection_sum += delta
		_check(enabled.get_size() == viewport.size and source_pixels > 50, phase[0] + "_source", source_pixels)
		_check(reflected_pixels > 10 and reflection_sum > 2.0, phase[0] + "_red_reflection", [reflected_pixels, reflection_sum])
		await _frames(4)
		var repeated := viewport.get_texture().get_image()
		var error := 0.0
		for y in viewport.size.y:
			for x in viewport.size.x:
				var a := enabled.get_pixel(x, y)
				var b := repeated.get_pixel(x, y)
				error += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
		error /= viewport.size.x * viewport.size.y * 3
		_check(error < 0.01, phase[0] + "_stable", error)
		if not output.is_empty():
			disabled.save_png(output.path_join(phase[0] + "-disabled.png"))
			enabled.save_png(output.path_join(phase[0] + "-enabled.png"))
	RenderingServer.call_on_render_thread(probe.release_gpu)
	RenderingServer.force_sync()
	while not probe.released:
		await get_tree().process_frame
	print("SSR_INTEGRATION COMPLETE passed=%d failed=%d" % [passed, failed])
	get_tree().quit(0 if failed == 0 and passed == 15 else 1)

func _mesh(mesh: Mesh, material: Material, position: Vector3) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	viewport.add_child(instance)

func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame
		var previous: int = probe.observed_frames
		RenderingServer.force_draw(false, 1.0 / 60.0)
		RenderingServer.force_sync()
		var deadline := Time.get_ticks_msec() + 5000
		while probe.observed_frames == previous and Time.get_ticks_msec() < deadline: await get_tree().process_frame
		if probe.observed_frames == previous: push_error("SSR compositor handoff timed out")

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
	if stable < 8: push_error("SSR pipelines did not settle")

func _check(condition: bool, label: String, detail: Variant = "") -> void:
	passed += int(condition)
	failed += int(not condition)
	print("SSR_INTEGRATION %s %s %s" % ["PASS" if condition else "FAIL", label, detail])
