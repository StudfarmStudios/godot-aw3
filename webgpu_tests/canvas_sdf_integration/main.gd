extends Node

var viewport: SubViewport
var rectangle: ColorRect
var occluder: LightOccluder2D
var material: ShaderMaterial
var passed := 0
var failed := 0
var output_directory := ""
var captures: Array[Dictionary] = []

func _ready() -> void:
	RenderingServer.render_loop_enabled = false
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--sdf-output="): output_directory = argument.trim_prefix("--sdf-output=")
	viewport = SubViewport.new()
	viewport.size = Vector2i(256, 192)
	viewport.use_hdr_2d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.sdf_scale = Viewport.SDF_SCALE_100_PERCENT
	viewport.sdf_oversize = Viewport.SDF_OVERSIZE_100_PERCENT
	add_child(viewport)
	rectangle = ColorRect.new()
	rectangle.size = viewport.size
	material = ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = """shader_type canvas_item;
render_mode unshaded;
uniform int visual_mode = 0;
void fragment() {
  vec2 position = screen_uv_to_sdf(SCREEN_UV);
  float distance = texture_sdf(position);
  if (visual_mode == 0) COLOR = vec4(distance < 0.0 ? vec3(1.0,0.0,0.0) : vec3(0.0,0.0,1.0),1.0);
  else if (visual_mode == 1) COLOR = vec4(vec3(clamp(0.5 + distance / 80.0,0.0,1.0)),1.0);
  else COLOR = vec4(texture_sdf_normal(position)*0.5+0.5,0.0,1.0);
}
"""
	rectangle.material = material
	viewport.add_child(rectangle)
	occluder = LightOccluder2D.new()
	occluder.occluder = OccluderPolygon2D.new()
	occluder.occluder.polygon = PackedVector2Array([Vector2(48,48),Vector2(112,48),Vector2(112,112),Vector2(48,112)])
	occluder.sdf_collision = true
	viewport.add_child(occluder)
	await _settle()
	var image := _capture("square_mask", 0)
	_mask_checks(image, Vector2i(80,80), Vector2i(20,20), "square")
	material.set_shader_parameter("visual_mode", 1)
	await _settle()
	image = _capture("square_distance", 1)
	var inside := image.get_pixel(80,80).r
	var outside := image.get_pixel(128,80).r
	_check(inside > 0.05 and inside < 0.20, "distance_inside", inside)
	_check(outside > 0.65 and outside < 0.80, "distance_outside", outside)
	material.set_shader_parameter("visual_mode", 2)
	await _settle()
	image = _capture("square_normals", 2)
	var right := image.get_pixel(128,80)
	var left := image.get_pixel(32,80)
	_check(right.r > 0.9 and right.g > 0.4 and right.g < 0.6, "normal_right", right)
	_check(left.r < 0.1 and left.g > 0.4 and left.g < 0.6, "normal_left", left)
	material.set_shader_parameter("visual_mode", 0)
	occluder.position.x = 80
	await _settle()
	image = _capture("moved_mask", 0)
	_mask_checks(image, Vector2i(160,80), Vector2i(80,80), "moved")
	occluder.position = Vector2.ZERO
	occluder.occluder.polygon = PackedVector2Array([Vector2(40,40),Vector2(120,40),Vector2(120,64),Vector2(64,64),Vector2(64,120),Vector2(40,120)])
	for scale: Array in [["full", Viewport.SDF_SCALE_100_PERCENT],["half", Viewport.SDF_SCALE_50_PERCENT],["quarter", Viewport.SDF_SCALE_25_PERCENT]]:
		viewport.sdf_scale = scale[1]
		await _settle()
		image = _capture("concave_" + scale[0], 0)
		_mask_checks(image, Vector2i(52,100), Vector2i(96,96), "concave_" + scale[0])
	viewport.size = Vector2i(193,131)
	rectangle.size = viewport.size
	occluder.position.x = 16
	await _settle()
	image = _capture("odd_resize", 0)
	_mask_checks(image, Vector2i(68,100), Vector2i(110,96), "odd_resize")
	viewport.sdf_scale = Viewport.SDF_SCALE_100_PERCENT
	viewport.sdf_oversize = Viewport.SDF_OVERSIZE_200_PERCENT
	occluder.position = Vector2.ZERO
	occluder.occluder.polygon = PackedVector2Array([Vector2(-20,48),Vector2(40,48),Vector2(40,112),Vector2(-20,112)])
	await _settle()
	image = _capture("oversize_clipped", 0)
	_mask_checks(image, Vector2i(10,80), Vector2i(70,80), "oversize_clipped")
	var file := FileAccess.open(output_directory.path_join("manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"captures":captures,"passed":passed,"failed":failed}, "\t"))
	print("CANVAS_SDF COMPLETE passed=%d failed=%d captures=%d" % [passed,failed,captures.size()])
	get_tree().quit(0 if failed == 0 and passed == 36 else 1)

func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame
		RenderingServer.force_draw(false,1.0/60.0)
		RenderingServer.force_sync()

func _settle() -> void:
	var stable := 0
	var previous := -1
	var deadline := Time.get_ticks_msec() + 60000
	while stable < 8 and Time.get_ticks_msec() < deadline:
		await _frames(1)
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW, RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]: requests += RenderingServer.get_rendering_info(source)
		stable = stable + 1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 and requests == previous else 0
		previous = requests
	if stable < 8: push_error("Canvas SDF pipelines did not settle")
	await _frames(2)

func _capture(label: String, mode: int) -> Image:
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBAF)
	_check(image.get_size() == viewport.size, label + "_extent")
	var finite := true
	if mode == 2:
		# SDF normals are undefined on equal-distance medial axes. Test the
		# well-defined left/right samples rather than demanding a normal there.
		for point in [Vector2i(32,80),Vector2i(128,80)]:
			var pixel := image.get_pixelv(point)
			finite = finite and is_finite(pixel.r) and is_finite(pixel.g)
	else:
		for value: float in image.get_data().to_float32_array(): finite = finite and is_finite(value) and value >= 0.0 and value <= 1.01
	_check(finite, label + "_finite")
	var file := FileAccess.open(output_directory.path_join(label + ".rgba32f"),FileAccess.WRITE)
	file.store_buffer(image.get_data())
	image.save_png(output_directory.path_join(label + ".png"))
	captures.append({"label":label,"width":viewport.size.x,"height":viewport.size.y,"mode":mode})
	return image

func _mask_checks(image: Image, inside: Vector2i, outside: Vector2i, label: String) -> void:
	var a := image.get_pixelv(inside)
	var b := image.get_pixelv(outside)
	_check(a.r > 0.9 and a.b < 0.1, label + "_inside", a)
	_check(b.b > 0.9 and b.r < 0.1, label + "_outside", b)

func _check(success: bool, label: String, detail: Variant = "") -> void:
	passed += int(success)
	failed += int(not success)
	print("CANVAS_SDF %s %s %s" % ["PASS" if success else "FAIL", label, detail])
