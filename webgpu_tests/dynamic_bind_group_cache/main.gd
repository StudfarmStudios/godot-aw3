extends Node

signal advance

# Forward+ supplies dynamic render-pass set 1/binding 2 through ShaderRD.
# Raw RDShaderSPIRV does not expose that metadata to GDScript.
const COLORS := [Color.RED, Color.GREEN, Color.BLUE, Color.WHITE]
var viewport: SubViewport
var meshes: Array[MeshInstance3D] = []
var materials: Array[ShaderMaterial] = []
var shaders: Array[Shader] = []
var passed := 0
var failed := 0
var browser_finished := false

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		advance.emit()

func _ready() -> void:
	print("DYNAMIC_BIND_GROUP DRIVER ", RenderingServer.get_current_rendering_driver_name(), " method=", RenderingServer.get_current_rendering_method())
	RenderingServer.render_loop_enabled = false
	get_tree().create_timer(180.0 if OS.has_feature("web") else 60.0).timeout.connect(func():
		if not browser_finished:
			push_error("DYNAMIC_BIND_GROUP timeout")
			get_tree().quit(2))
	viewport = SubViewport.new()
	viewport.size = Vector2i(96, 64)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = false
	add_child(viewport)
	if OS.has_feature("web"):
		# Browser readback is asynchronous. Present the exact viewport for the
		# harness to check its pixels, without a synchronous GPU readback call.
		var presentation := TextureRect.new()
		presentation.texture = viewport.get_texture()
		presentation.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		presentation.position = Vector2.ZERO
		presentation.size = Vector2(96, 64)
		add_child(presentation)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 3.0
	viewport.add_child(camera)
	camera.current = true
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	viewport.add_child(world)
	for index in 2:
		var shader := Shader.new()
		shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; uniform vec3 test_color; void fragment() { ALBEDO = test_color; %s }" % ("ALPHA = 1.0;" if index == 1 else "")
		shaders.append(shader)
	for index in 8:
		var mesh := MeshInstance3D.new()
		mesh.mesh = QuadMesh.new()
		mesh.mesh.size = Vector2(0.24, 0.45)
		var material := ShaderMaterial.new()
		material.shader = shaders[index % 2]
		material.set_shader_parameter("test_color", Vector3(1.0, 0.0, 0.0))
		mesh.material_override = material
		mesh.position = _position(index, 0)
		viewport.add_child(mesh)
		meshes.append(mesh)
		materials.append(material)
	if not await _wait_for_pipelines():
		return
	# Color data and instance transforms change independently. Each phase uses
	# a new frame slice; intervening opaque/alpha passes and shader changes
	# must not reuse a stale encoder's group or a stale offset tuple.
	for phase in 12:
		for index in 8:
			meshes[index].position = _position(index, phase)
			materials[index].shader = shaders[(index + phase / 3) % 2]
			var color: Color = COLORS[(index + phase) % COLORS.size()]
			materials[index].set_shader_parameter("test_color", Vector3(color.r, color.g, color.b))
		await _frame()
		# A render worker can consume the first forced frame before SceneTree's
		# deferred transform propagation. Capture after a fixed second frame.
		await _frame()
		if OS.has_feature("web"):
			print("DYNAMIC_BIND_GROUP PHASE ", JSON.stringify({"phase": phase, "width": viewport.size.x, "height": viewport.size.y}))
			await advance
			continue
		var image := viewport.get_texture().get_image()
		for index in 8:
			var color: Color = COLORS[(index + phase) % COLORS.size()]
			_check(_near(image, _pixel(_position(index, phase)), color), "phase_%02d_tile_%d" % [phase, index])
			_check(_near(image, _pixel(_position(index, phase + 1)), Color.BLACK), "phase_%02d_empty_%d" % [phase, index])
	if OS.has_feature("web"):
		browser_finished = true
		print("DYNAMIC_BIND_GROUP BROWSER_DONE phases=12")
	else:
		print("DYNAMIC_BIND_GROUP COMPLETE passed=%d failed=%d" % [passed, failed])
		get_tree().quit(0 if failed == 0 else 1)

func _position(index: int, phase: int) -> Vector3:
	return Vector3(-1.25 + (index % 4) * 0.75 + (0.3 if phase % 2 else 0.0), 0.5 if index < 4 else -0.5, 0.0)

func _pixel(position: Vector3) -> Vector2i:
	return Vector2i(roundi((position.x + 1.5) * 32.0), roundi((1.0 - position.y) * 32.0))

func _near(image: Image, pixel: Vector2i, expected: Color) -> bool:
	if image.get_size() != Vector2i(96, 64):
		return false
	for y in range(pixel.y - 1, pixel.y + 2):
		for x in range(pixel.x - 1, pixel.x + 2):
			var actual := image.get_pixel(x, y)
			if maxf(absf(actual.r - expected.r), maxf(absf(actual.g - expected.g), absf(actual.b - expected.b))) > 0.02:
				print("DYNAMIC_BIND_GROUP PIXEL %s expected=%s actual=%s" % [Vector2i(x, y), expected, actual])
				return false
	return true

func _check(success: bool, label: String) -> void:
	passed += int(success)
	failed += int(not success)
	print("DYNAMIC_BIND_GROUP %s %s" % ["PASS" if success else "FAIL", label])

func _frame() -> void:
	await get_tree().process_frame
	RenderingServer.force_draw(OS.has_feature("web"), 1.0 / 60.0)
	RenderingServer.force_sync()

func _wait_for_pipelines() -> bool:
	var start := Time.get_ticks_msec()
	var previous_requests := -1
	var stable := 0
	var frame := 0
	while Time.get_ticks_msec() - start < 30000:
		frame += 1
		await _frame()
		var pending := RenderingServer.get_pending_pipeline_compilation_count()
		var requests := 0
		for source in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]:
			requests += RenderingServer.get_rendering_info(source)
		stable = stable + 1 if pending == 0 and requests == previous_requests else 0
		previous_requests = requests
		if frame >= 8 and stable >= 4:
			print("DYNAMIC_BIND_GROUP READY frames=%d pending=%d requests=%d" % [frame + 1, pending, requests])
			return true
		if Time.get_ticks_msec() - start > 30000:
			break
	push_error("DYNAMIC_BIND_GROUP pipeline timeout")
	get_tree().quit(2)
	return false
