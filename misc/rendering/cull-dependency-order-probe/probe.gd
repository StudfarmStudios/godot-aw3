extends Node

# This fixture deliberately submits all frame-1 RenderingServer mutations in one
# command batch. A query, force_draw, or await inside _exercise_partial_drain()
# would drain the dirty list and invalidate the regression.

const VIEW_SIZE := Vector2i(640, 480)
const CAPTURES := [0, 1, 2, 4, 8]
const BACKGROUND := Color(0.012, 0.018, 0.028)
const WARMUP_FRAMES := 31
const MIN_FOREGROUND_PIXELS := 256

var output := "user://cull-dependency-order-probe"
var viewport: SubViewport
var world: Node3D
var scenario: RID

var owned_rids: Array[RID] = []
var live_instances: Array[RID] = []

var transparent_shader: RID
var opaque_shader: RID
var lit_shader: RID
var transparent_mesh: RID
var opaque_mesh: RID
var lit_mesh: RID

var order_a: RID
var order_b: RID
var order_a_final_material: RID
var order_b_final_material: RID

var lit_survivor: RID
var light: RID
var light_instance: RID

var particles: RID
var particles_instance: RID
var collider: RID
var collider_instance: RID

var deferred_survivor: RID
var deferred_base_material: RID
var deferred_material: RID
var free_target_a: RID
var free_target_b: RID

var frame := -WARMUP_FRAMES
var label := -1
var capture_pending := false
var deadline_msec := 0
var done := false
var quit_countdown := 0
var exercised := false
var hashes: Dictionary = {}
var foreground: Dictionary = {}
var sample_colors: Dictionary = {}
var failures: Array[String] = []
var events: Array[String] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	_build_fixture()
	deadline_msec = Time.get_ticks_msec() + 30_000
	RenderingServer.frame_post_draw.connect(_capture)


func _build_fixture() -> void:
	viewport = SubViewport.new()
	viewport.name = "FixtureViewport"
	viewport.size = VIEW_SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = false
	add_child(viewport)

	world = Node3D.new()
	world.name = "FixtureWorld"
	viewport.add_child(world)
	scenario = world.get_world_3d().scenario
	_require(viewport.own_world_3d, "SubViewport must own its World3D")
	_require(scenario.is_valid(), "fixture scenario RID is invalid")
	_require(world.get_world_3d().scenario == scenario, "fixture nodes and direct instances do not share a scenario")

	var environment_node := WorldEnvironment.new()
	environment_node.environment = Environment.new()
	environment_node.environment.background_mode = Environment.BG_COLOR
	environment_node.environment.background_color = BACKGROUND
	environment_node.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment_node.environment.ambient_light_color = Color(0.018, 0.018, 0.022)
	environment_node.environment.ambient_light_energy = 0.06
	world.add_child(environment_node)

	var camera := Camera3D.new()
	camera.name = "FixtureCamera"
	camera.position = Vector3(0, 0, 12)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.0
	camera.current = true
	world.add_child(camera)

	transparent_shader = _make_shader("shader_type spatial; render_mode unshaded, cull_disabled, depth_draw_never; uniform vec4 tint : source_color = vec4(1.0); void fragment() { ALBEDO = tint.rgb; ALPHA = tint.a; }")
	opaque_shader = _make_shader("shader_type spatial; render_mode unshaded, cull_disabled; uniform vec4 tint : source_color = vec4(1.0); void fragment() { ALBEDO = tint.rgb; }")
	lit_shader = _make_shader("shader_type spatial; render_mode cull_disabled; void fragment() { ALBEDO = vec3(0.92); ROUGHNESS = 0.82; } void light() { DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR; }")

	var order_a_initial := _make_material(transparent_shader, Color(0.98, 0.12, 0.08, 0.54))
	var order_b_initial := _make_material(transparent_shader, Color(0.08, 0.30, 1.0, 0.56))
	order_a_final_material = _make_material(transparent_shader, Color(1.0, 0.18, 0.05, 0.52))
	order_b_final_material = _make_material(transparent_shader, Color(0.04, 0.48, 1.0, 0.58))
	transparent_mesh = _make_quad_mesh(1.18, order_a_initial)
	order_a = _make_instance(transparent_mesh, Vector3(-2.05, 1.35, 0.0))
	order_b = _make_instance(transparent_mesh, Vector3(-2.05, 1.35, 0.0))
	RenderingServer.instance_geometry_set_material_override(order_b, order_b_initial)

	var lit_material := _make_material(lit_shader, Color.WHITE)
	lit_mesh = _make_quad_mesh(0.82, lit_material)
	# A planar surface has a zero-depth generated AABB. Give the pairing oracle a
	# small volume so the geometry and omni-light DynamicBVHs overlap robustly.
	RenderingServer.mesh_set_custom_aabb(lit_mesh, AABB(Vector3(-0.82, -0.82, -0.08), Vector3(1.64, 1.64, 0.16)))
	lit_survivor = _make_instance(lit_mesh, Vector3(4.5, 0.45, 0.0))
	light = _own(RenderingServer.omni_light_create())
	RenderingServer.light_set_color(light, Color(1.0, 0.62, 0.22))
	RenderingServer.light_set_param(light, RenderingServer.LIGHT_PARAM_ENERGY, 12.0)
	RenderingServer.light_set_param(light, RenderingServer.LIGHT_PARAM_RANGE, 3.0)
	light_instance = _make_instance(light, Vector3(0.5, 0.45, 1.25))

	particles = _own(RenderingServer.particles_create())
	RenderingServer.particles_set_amount(particles, 1)
	RenderingServer.particles_set_custom_aabb(particles, AABB(Vector3(-0.6, -0.6, -0.6), Vector3(1.2, 1.2, 1.2)))
	RenderingServer.particles_set_emitting(particles, false)
	particles_instance = _make_instance(particles, Vector3(4.0, -2.4, 0.0))
	collider = _own(RenderingServer.particles_collision_create())
	RenderingServer.particles_collision_set_collision_type(collider, RenderingServer.PARTICLES_COLLISION_TYPE_SPHERE_COLLIDE)
	RenderingServer.particles_collision_set_sphere_radius(collider, 1.1)
	RenderingServer.particles_collision_set_cull_mask(collider, 1)
	collider_instance = _make_instance(collider, Vector3(4.0, -2.4, 0.0))

	deferred_base_material = _make_material(opaque_shader, Color(0.08, 0.72, 0.96, 1.0))
	deferred_material = _make_material(opaque_shader, Color(1.0, 0.16, 0.04, 1.0))
	opaque_mesh = _make_quad_mesh(0.70, deferred_base_material)
	deferred_survivor = _make_instance(opaque_mesh, Vector3(0.0, -2.35, 0.0))
	RenderingServer.instance_geometry_set_material_override(deferred_survivor, deferred_material)

	free_target_a = _make_instance(opaque_mesh, Vector3(12.0, 0.0, 0.0))
	free_target_b = _make_instance(opaque_mesh, Vector3(14.0, 0.0, 0.0))


func _make_shader(code: String) -> RID:
	var shader := _own(RenderingServer.shader_create())
	RenderingServer.shader_set_code(shader, code)
	return shader


func _make_material(shader: RID, color: Color) -> RID:
	var material := _own(RenderingServer.material_create())
	RenderingServer.material_set_shader(material, shader)
	RenderingServer.material_set_param(material, "tint", color)
	return material


func _make_quad_mesh(radius: float, material: RID) -> RID:
	var mesh := _own(RenderingServer.mesh_create())
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-radius, -radius, 0), Vector3(radius, -radius, 0),
		Vector3(radius, radius, 0), Vector3(-radius, radius, 0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1),
	])
	# Godot uses clockwise front faces; keep the +Z normals facing the camera/light.
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	RenderingServer.mesh_add_surface_from_arrays(mesh, RenderingServer.PRIMITIVE_TRIANGLES, arrays)
	RenderingServer.mesh_surface_set_material(mesh, 0, material)
	return mesh


func _make_instance(base: RID, position: Vector3) -> RID:
	var instance := _own(RenderingServer.instance_create2(base, scenario))
	live_instances.append(instance)
	RenderingServer.instance_set_transform(instance, Transform3D(Basis.IDENTITY, position))
	return instance


func _process(_delta: float) -> void:
	if done:
		quit_countdown -= 1
		if quit_countdown <= 0:
			get_tree().quit(0 if failures.is_empty() else 2)
		return
	if Time.get_ticks_msec() >= deadline_msec:
		_fail("timed out waiting for captures: missing=%s" % [_missing_captures()])
		_finish()
		return
	if capture_pending:
		return

	frame += 1
	if frame < 0:
		return
	if frame == 1:
		_exercise_partial_drain()
	label = frame
	capture_pending = label in CAPTURES


func _exercise_partial_drain() -> void:
	_require(not exercised, "partial-drain sequence ran more than once")
	exercised = true

	# General list order becomes B, A. A dependency-only side list would instead
	# become A, B because A is upgraded in place after B was inserted. The scan
	# implementation must retain the original B, A dependency order.
	RenderingServer.instance_set_transform(order_a, Transform3D(Basis.IDENTITY, Vector3(-2.03, 1.35, 0.0)))
	RenderingServer.instance_geometry_set_material_override(order_b, order_b_final_material)
	RenderingServer.instance_geometry_set_material_override(order_a, order_a_final_material)

	# Leave two paired survivors transform-dirty while dependency work is pending.
	# The light is unpaired/repaired against the geometry's old BVH position; the
	# collider is similarly repaired against the particle's old position. The next
	# ordinary scene drain must converge both after the partial free-time drain.
	RenderingServer.instance_set_transform(lit_survivor, Transform3D(Basis.IDENTITY, Vector3(0.5, 0.45, 0.0)))
	RenderingServer.light_set_cull_mask(light, 1)
	RenderingServer.instance_set_transform(particles_instance, Transform3D(Basis.IDENTITY, Vector3(7.5, -2.4, 0.0)))
	RenderingServer.particles_collision_set_cull_mask(collider, 1)

	# This uniform upload emits DEPENDENCY_CHANGED_MATERIAL from
	# update_dirty_resources(), after the first dependency scan. The second
	# unrelated instance free must consume that newly queued dependency update.
	RenderingServer.material_set_param(deferred_material, "tint", Color(0.90, 0.22, 0.03, 1.0))
	_free_instance(free_target_a)
	free_target_a = RID()
	_free_instance(free_target_b)
	free_target_b = RID()
	_free_owned(deferred_material)
	deferred_material = RID()
	events.append("frame1: A AABB; B dependency; A dependency upgrade; move lit and particle survivors; refresh light/collider pairing; dirty material; free two unrelated instances; free dirty material")


func _capture() -> void:
	if done or not capture_pending:
		return
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		_fail("frame %d readback is empty" % label)
		_finish()
		return
	image.convert(Image.FORMAT_RGBA8)
	var background := image.get_pixel(0, 0)
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b) > 0.08:
				count += 1
	foreground[str(label)] = count
	if count < MIN_FOREGROUND_PIXELS:
		_fail("frame %d is blank: foreground=%d" % [label, count])

	var overlap := image.get_pixel(156, 159)
	# Orthographic camera mapping: the quad starts at (590, 213), outside the
	# light, and moves to (350, 213), directly below it. Sampling both locations
	# distinguishes an actually lit move from a coordinate mistake.
	var lit_old_sample := image.get_pixel(590, 213)
	var lit_sample := image.get_pixel(350, 213)
	var deferred_sample := image.get_pixel(320, 381)
	sample_colors[str(label)] = {
		"overlap": _color_array(overlap),
		"lit": _color_array(lit_sample),
		"lit_old": _color_array(lit_old_sample),
		"deferred": _color_array(deferred_sample),
	}
	if label == 0:
		if lit_old_sample.r > 0.04 or lit_old_sample.g > 0.04 or lit_old_sample.b > 0.04:
			_fail("frame 0 old geometry location was expected to be unlit: %s" % lit_old_sample)
		if _color_delta(lit_sample, background) > 0.04:
			_fail("frame 0 future geometry location was not background: sample=%s background=%s" % [lit_sample, background])
	else:
		if overlap.r < 0.08 or overlap.b < 0.08:
			_fail("frame %d transparent overlap lost a layer: %s" % [label, overlap])
		if lit_sample.r < 0.20 or lit_sample.g < 0.08:
			_fail("frame %d moved geometry was not lit: %s" % [label, lit_sample])
		if _color_delta(lit_old_sample, background) > 0.04:
			_fail("frame %d old geometry location was not cleared: sample=%s background=%s" % [label, lit_old_sample, background])
		if deferred_sample.b < deferred_sample.r + 0.20 or deferred_sample.b < 0.45:
			_fail("frame %d deferred material deletion did not restore blue base: %s" % [label, deferred_sample])

	var path := output.path_join("frame-%03d.png" % label)
	var save_error := image.save_png(path)
	if save_error != OK:
		_fail("frame %d save failed: %s" % [label, error_string(save_error)])
	else:
		hashes[str(label)] = FileAccess.get_sha256(path)
	capture_pending = false
	if label == CAPTURES[-1]:
		_finish()


func _finish() -> void:
	if done:
		return
	done = true
	var missing := _missing_captures()
	if not missing.is_empty():
		_fail("capture set incomplete: missing=%s captured=%d expected=%d" % [missing, hashes.size(), CAPTURES.size()])
	_require(exercised, "partial-drain sequence never ran")
	var metadata := {
		"format": 2,
		"sha256": hashes,
		"foreground": foreground,
		"sample_colors": sample_colors,
		"events": events,
		"config": {
			"captures": CAPTURES,
			"fixed_fps": 60,
			"warmup_frames": WARMUP_FRAMES,
			"viewport": [VIEW_SIZE.x, VIEW_SIZE.y],
			"taa": false,
			"renderer": RenderingServer.get_current_rendering_method(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
		},
		"failures": failures,
	}
	var file := FileAccess.open(output.path_join("metadata.json"), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(metadata, "\t") + "\n")
		file.close()
	else:
		_fail("metadata open failed: %s" % error_string(FileAccess.get_open_error()))
	print("CULL_DEPENDENCY_ORDER %s captures=%d" % ["PASS" if failures.is_empty() else "FAIL", hashes.size()])
	_cleanup()
	quit_countdown = 3


func _missing_captures() -> Array[int]:
	var missing: Array[int] = []
	for required in CAPTURES:
		if not hashes.has(str(required)):
			missing.append(int(required))
	return missing


func _color_array(color: Color) -> Array[float]:
	return [color.r, color.g, color.b, color.a]


func _color_delta(a: Color, b: Color) -> float:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)


func _own(rid: RID) -> RID:
	owned_rids.append(rid)
	return rid


func _free_instance(rid: RID) -> void:
	if rid.is_valid() and rid in live_instances:
		RenderingServer.free_rid(rid)
		live_instances.erase(rid)
		owned_rids.erase(rid)


func _free_owned(rid: RID) -> void:
	if rid.is_valid() and rid in owned_rids:
		RenderingServer.free_rid(rid)
		owned_rids.erase(rid)


func _cleanup() -> void:
	# Instance teardown precedes all remaining shared bases and materials.
	for rid in live_instances.duplicate():
		_free_instance(rid)
	for rid in owned_rids.duplicate():
		_free_owned(rid)
	if RenderingServer.frame_post_draw.is_connected(_capture):
		RenderingServer.frame_post_draw.disconnect(_capture)
	viewport.queue_free()


func _require(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	failures.append(message)
	push_error("[CULL_DEPENDENCY_ORDER] " + message)
