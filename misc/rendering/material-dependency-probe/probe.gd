extends Node

const CAPTURES := [0, 1, 2, 4, 8]
const BACKGROUND := Color(0.012, 0.018, 0.028)
const BASE_COLOR := Color(0.12, 0.72, 0.94)

var output := "user://material-dependency-probe"
var viewport: SubViewport
var world: Node3D
var scenario: RID
var shader: RID
var base_material: RID
var mesh: RID
var survivor: RID
var unrelated_target: RID
var doomed_material: RID
var owned_rids: Array[RID] = []

var frame := -31
var label := -1
var capture_pending := false
var deadline_msec := 0
var done := false
var quit_countdown := 0
var hashes: Dictionary = {}
var foreground: Dictionary = {}
var center_colors: Dictionary = {}
var failures: Array[String] = []
var events: Array[String] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	_setup_scene()
	deadline_msec = Time.get_ticks_msec() + 30_000
	RenderingServer.frame_post_draw.connect(_capture)


func _setup_scene() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(512, 384)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	scenario = world.get_world_3d().scenario

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = BACKGROUND
	world.add_child(environment)

	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 8)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 5.0
	camera.current = true
	world.add_child(camera)

	shader = _own(RenderingServer.shader_create())
	RenderingServer.shader_set_code(shader, "shader_type spatial; render_mode unshaded, cull_disabled; uniform vec4 tint : source_color = vec4(1.0); void fragment() { ALBEDO = tint.rgb; }")
	base_material = _make_material(BASE_COLOR)
	mesh = _make_quad_mesh(1.25, base_material)
	survivor = _make_instance(mesh, Vector3.ZERO)
	unrelated_target = _make_instance(mesh, Vector3(4, 0, 0))


func _make_material(color: Color) -> RID:
	var material := _own(RenderingServer.material_create())
	RenderingServer.material_set_shader(material, shader)
	RenderingServer.material_set_param(material, "tint", color)
	return material


func _make_quad_mesh(radius: float, material: RID) -> RID:
	var result := _own(RenderingServer.mesh_create())
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-radius, -radius, 0), Vector3(radius, -radius, 0),
		Vector3(radius, radius, 0), Vector3(-radius, radius, 0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	RenderingServer.mesh_add_surface_from_arrays(result, RenderingServer.PRIMITIVE_TRIANGLES, arrays)
	RenderingServer.mesh_surface_set_material(result, 0, material)
	return result


func _make_instance(base: RID, position: Vector3) -> RID:
	var instance := _own(RenderingServer.instance_create2(base, scenario))
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

	# Capture frame 0 after the initial resources have been fully registered.
	# The three frame-1 calls must stay consecutive: inserting a query, draw, or
	# sync here would drain the dirty survivor and hide the regression.
	if frame == 1:
		doomed_material = _make_material(Color(1.0, 0.10, 0.04))
		RenderingServer.instance_geometry_set_material_override(survivor, doomed_material)
		_free_owned(unrelated_target)
		unrelated_target = RID()
		_free_owned(doomed_material)
		doomed_material = RID()
		events.append("assign fresh override to survivor; free unrelated instance; free override material in one command batch")

	label = frame
	capture_pending = label in CAPTURES


func _capture() -> void:
	if done or not capture_pending:
		return
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	var background := image.get_pixel(0, 0)
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b) > 0.08:
				count += 1
	var center := image.get_pixel(image.get_width() >> 1, image.get_height() >> 1)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(image.get_data())
	hashes[str(label)] = hash.finish().hex_encode()
	foreground[str(label)] = count
	center_colors[str(label)] = [center.r, center.g, center.b, center.a]
	if count < 64:
		_fail("frame %d is blank: foreground=%d" % [label, count])
	# A correctly delivered dependency-deletion callback clears the temporary
	# override before it can be drawn, leaving the survivor's blue base material.
	if center.b < center.r + 0.25 or center.b < 0.55:
		_fail("frame %d survivor did not use base material: center=%s" % [label, center])
	var save_error := image.save_png(output.path_join("frame-%03d.png" % label))
	if save_error != OK:
		_fail("frame %d save failed: %s" % [label, error_string(save_error)])
	capture_pending = false
	if label == CAPTURES[-1]:
		_finish()


func _finish() -> void:
	done = true
	var missing := _missing_captures()
	if not missing.is_empty():
		_fail("capture set incomplete: missing=%s captured=%d expected=%d" % [missing, hashes.size(), CAPTURES.size()])
	var metadata := {
		"sha256": hashes,
		"foreground": foreground,
		"center_colors": center_colors,
		"events": events,
		"config": {
			"captures": CAPTURES,
			"fixed_fps": 60,
			"warmup_frames": 31,
			"driver": RenderingServer.get_current_rendering_driver_name(),
		},
		"failures": failures,
	}
	var file := FileAccess.open(output.path_join("metadata.json"), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(metadata, "\t"))
		file.close()
	else:
		_fail("metadata open failed: %s" % error_string(FileAccess.get_open_error()))
	print("MATERIAL_DEPENDENCY %s captures=%d" % ["PASS" if failures.is_empty() else "FAIL", hashes.size()])
	_cleanup()
	quit_countdown = 3


func _missing_captures() -> Array[int]:
	var missing: Array[int] = []
	for required in CAPTURES:
		if not hashes.has(str(required)):
			missing.append(int(required))
	return missing


func _own(rid: RID) -> RID:
	owned_rids.append(rid)
	return rid


func _free_owned(rid: RID) -> void:
	if rid.is_valid():
		RenderingServer.free_rid(rid)
		owned_rids.erase(rid)


func _cleanup() -> void:
	# Free live instances before shared bases. Test-deleted RIDs were removed.
	_free_owned(survivor)
	survivor = RID()
	_free_owned(unrelated_target)
	unrelated_target = RID()
	for rid in owned_rids.duplicate():
		_free_owned(rid)
	viewport.queue_free()


func _fail(message: String) -> void:
	failures.append(message)
	push_error("[MATERIAL_DEPENDENCY] " + message)
