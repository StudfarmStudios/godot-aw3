extends Node3D

signal advance
var content: Node
var world: WorldEnvironment
var camera: Camera3D
var fonts: Array[FontFile] = []

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		advance.emit()

func _ready() -> void:
	print("BROWSER_DRIVER ", RenderingServer.get_current_rendering_driver_name(), " method=", RenderingServer.get_current_rendering_method(), " threads=", OS.has_feature("threads"))
	if RenderingServer.get_current_rendering_driver_name() != "webgpu" or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("BROWSER_WRONG_RENDERER")
		return
	var rebind := preload("res://rebind_lifecycle.gd").new()
	add_child(rebind)
	var native_rebind_only := "--rebind-native-only" in OS.get_cmdline_user_args()
	if not await rebind.run(native_rebind_only):
		return
	rebind.queue_free()
	if native_rebind_only:
		get_tree().quit()
		return
	content = Node.new()
	add_child(content)
	for index in 4:
		var font := FontFile.new()
		var imported_font: FontFile = load("res://authored-svg.ttf" if index == 3 else "res://inter.woff2")
		if imported_font == null or imported_font.data.is_empty():
			push_error("BROWSER_FONT_SOURCE_MISSING ", index)
			return
		font.data = imported_font.data
		font.allow_system_fallback = false
		if not font.has_char(65) or not font.has_char(66):
			push_error("BROWSER_FONT_GLYPH_MISSING ", index)
			return
		if index == 1: font.antialiasing = TextServer.FONT_ANTIALIASING_LCD
		if index == 2: font.multichannel_signed_distance_field = true
		fonts.append(font)
		var label := Label.new()
		label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", 48)
		label.add_theme_color_override("font_color", Color.RED)
		label.position = Vector2(30, index * 88)
		label.text = "A"
		content.add_child(label)
	await _settle()
	for node in content.get_children(): node.text = "BBBB" # New glyph in an existing atlas.
	await _phase("font")
	await _clear()
	var rectangle := ColorRect.new()
	rectangle.size = Vector2(512,384)
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = """shader_type canvas_item;
render_mode unshaded;
void fragment(){float d=texture_sdf(screen_uv_to_sdf(SCREEN_UV));COLOR=vec4(d<0.0?vec3(1,0,0):vec3(0,0,1),1);}
"""
	rectangle.material = material
	content.add_child(rectangle)
	var occluder := LightOccluder2D.new()
	occluder.occluder = OccluderPolygon2D.new()
	occluder.occluder.polygon = PackedVector2Array([Vector2(48,48),Vector2(112,48),Vector2(112,112),Vector2(48,112)])
	occluder.sdf_collision = true
	content.add_child(occluder)
	await _phase("canvas_sdf")
	await _clear()
	_scene3d()
	camera.position = Vector3(0,2.6,6)
	camera.look_at(Vector3(0,0.2,0))
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.2
	world.environment.ssr_max_steps = 128
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.7,0.7,0.7)
	floor_material.metallic = 0.9
	floor_material.roughness = 0.12
	var plane := PlaneMesh.new()
	plane.size = Vector2(12,12)
	_mesh(plane,floor_material,Vector3(0,-0.6,0))
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(1,0.015,0.01)
	red.emission_enabled = true
	red.emission = Color.RED
	red.emission_energy_multiplier = 2.0
	var box := BoxMesh.new()
	box.size = Vector3(1.4,1.4,1.4)
	_mesh(box,red,Vector3(0,0.2,0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55,-25,0)
	light.light_energy = 1.2
	content.add_child(light)
	await _phase("ssr_off")
	world.environment.ssr_enabled = true
	await _phase("ssr_on")
	await _clear()
	_scene3d()
	camera.position.z = 10
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6
	var attributes := CameraAttributesPractical.new()
	attributes.dof_blur_near_distance = 4
	attributes.dof_blur_near_transition = 1
	attributes.dof_blur_far_distance = 8
	attributes.dof_blur_far_transition = 1
	attributes.dof_blur_amount = 0.25
	camera.attributes = attributes
	for index in 3:
		var panel := QuadMesh.new()
		panel.size = Vector2(1.5,3)
		var checker := ShaderMaterial.new()
		checker.shader = Shader.new()
		checker.shader.code = "shader_type spatial; render_mode unshaded,cull_disabled; void fragment(){float a=mod(floor(UV.x*16.0)+floor(UV.y*32.0),2.0);ALBEDO=vec3(a);}"
		_mesh(panel,checker,Vector3((index-1)*2,0,[7,4,0][index]))
	await _phase("dof_off")
	attributes.dof_blur_near_enabled = true
	attributes.dof_blur_far_enabled = true
	await _phase("dof_on")
	print("BROWSER_DONE")

func _clear() -> void:
	content.queue_free()
	await get_tree().process_frame
	content = Node.new()
	add_child(content)

func _scene3d() -> void:
	camera = Camera3D.new()
	content.add_child(camera)
	camera.current = true
	world = WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.015,0.015,0.015)
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	content.add_child(world)

func _mesh(mesh: Mesh, material: Material, position: Vector3) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	content.add_child(instance)

func _settle() -> void:
	var stable := 0
	var previous := -1
	var deadline := Time.get_ticks_msec() + 60000
	while stable < 12 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]: requests += RenderingServer.get_rendering_info(source)
		stable = stable + 1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 and requests == previous else 0
		previous = requests
	if stable < 12: push_error("BROWSER_PIPELINES_DID_NOT_SETTLE")
	await get_tree().process_frame

func _phase(name: String) -> void:
	await _settle()
	print("BROWSER_READY ", name)
	await advance
