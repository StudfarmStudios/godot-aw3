extends Node

var viewport: Viewport

func frames(count: int) -> void:
	for frame in range(count):
		await get_tree().process_frame
		RenderingServer.force_draw(false)

func capture() -> Image:
	await frames(30)
	for frame in range(1200):
		if RenderingServer.get_pending_pipeline_compilation_count() == 0:
			break
		await get_tree().process_frame
	# Discard readbacks queued before this state change on browser WebGPU.
	for flush in range(2):
		viewport.get_texture().get_image()
		await frames(4)
	for attempt in range(180):
		var result := viewport.get_texture().get_image()
		if result != null and not result.is_empty():
			return result
		await get_tree().process_frame
	push_error("SHADOW_ATLAS readback timed out")
	get_tree().quit(1)
	return null

func brightness(image: Image) -> float:
	var total := 0.0
	for y in range(345, 370):
		for x in range(540, 590):
			total += image.get_pixel(x, y).r
	return total / 1250.0

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	viewport = get_tree().root
	var quadrant := 3
	var use_16_bits := true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quadrant="):
			quadrant = int(arg.get_slice("=", 1))
		if arg == "--depth=32":
			use_16_bits = false
	assert(quadrant >= 0 and quadrant < 4)
	viewport.positional_shadow_atlas_size = 4096
	viewport.positional_shadow_atlas_16_bits = use_16_bits
	for q in range(4):
		viewport.set_positional_shadow_atlas_quadrant_subdiv(q, Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_4 if q == quadrant else Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.03, 0.03, 0.03)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.04
	environment.environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	viewport.add_child(environment)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(7, 7, 10)
	camera.look_at(Vector3.ZERO)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.roughness = 1.0
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	floor_mesh.mesh.size = Vector2(20, 20)
	floor_mesh.material_override = material
	viewport.add_child(floor_mesh)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.mesh.size = Vector3(2, 2, 2)
	box.material_override = material
	box.position = Vector3(0, 1, 0)
	viewport.add_child(box)
	var light := OmniLight3D.new()
	light.position = Vector3(-3, 5, 3)
	light.light_energy = 8.0
	light.omni_range = 20.0
	light.shadow_enabled = true
	light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	viewport.add_child(light)
	# Both hemispheres sit away from the atlas origin. Clearing the second
	# tile must preserve the first, and a moving caster must erase its old shadow.
	var shadow := brightness(await capture())
	box.position = Vector3(-4, 1, -4)
	var moved := brightness(await capture())
	light.shadow_enabled = false
	var lit := brightness(await capture())
	var passed := shadow < 0.4 and lit > 0.65 and moved > lit * 0.9
	print("SHADOW_ATLAS quadrant=%d depth=%d %s shadow=%.4f moved=%.4f lit=%.4f" % [quadrant, 16 if use_16_bits else 32, "PASS" if passed else "FAIL", shadow, moved, lit])
	print("SHADOW_ATLAS COMPLETE failures=%d" % (0 if passed else 1))
	get_tree().quit(0 if passed else 1)
