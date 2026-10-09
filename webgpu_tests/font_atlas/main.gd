extends Node

# The runner supplies the repository's redistributable Inter font, so the fixture
# uses the same font bytes on every host without copying an asset into the project.
var font_data: PackedByteArray
var passed := 0
var failed := 0
var benchmark_only := false
var require_deferred := true
var server_filter := "all"

class GlyphCanvas extends Node2D:
	var ts: TextServer
	var font: RID
	var glyphs: Array[int]
	func _draw() -> void:
		for i in glyphs.size():
			ts.font_draw_glyph(font, get_canvas_item(), 32, Vector2(8 + i * 24, 8), glyphs[i], Color.RED, 1.0)

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--font="):
			font_data = FileAccess.get_file_as_bytes(arg.trim_prefix("--font="))
		if arg.begins_with("--server="):
			server_filter = arg.trim_prefix("--server=")
		if arg == "--benchmark":
			benchmark_only = true
		if arg == "--immediate":
			require_deferred = false
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if value:
		passed += 1
		print("FONT_TEST PASS ", message)
	else:
		failed += 1
		printerr("FONT_TEST FAIL ", message)

func draw_frame() -> void:
	# With a separate render thread, the next delivered frame_post_draw may
	# describe an older frame already submitted before these glyph requests.
	# Explicitly submit and finish this frame so first-frame checks are exact.
	RenderingServer.force_draw(false)
	RenderingServer.force_sync()

func make_font(ts: TextServer, mipmaps := false) -> RID:
	var font := ts.create_font()
	ts.font_set_data(font, font_data)
	ts.font_set_subpixel_positioning(font, TextServer.SUBPIXEL_POSITIONING_DISABLED)
	ts.font_set_generate_mipmaps(font, mipmaps)
	return font

func pixels(image: Image, mipmaps := false) -> PackedByteArray:
	var copy := image.duplicate() as Image
	if mipmaps and not copy.has_mipmaps():
		copy.generate_mipmaps()
	copy.convert(Image.FORMAT_RGBA8)
	return copy.get_data()

func same_pixels(actual: PackedByteArray, expected: PackedByteArray, label: String) -> bool:
	if actual == expected:
		return true
	var differences: Array[String] = []
	for i in mini(actual.size(), expected.size()):
		if actual[i] != expected[i]:
			differences.append("%d:%d/%d" % [i, actual[i], expected[i]])
			if differences.size() == 8:
				break
	print("FONT_TEST PIXEL_DIFF ", label, " actual_bytes=", actual.size(), " expected_bytes=", expected.size(), " offsets:actual/expected=", differences)
	return false

func gpu_pixels(texture: RID) -> PackedByteArray:
	var result := {"data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		var source := RenderingServer.texture_get_rd_texture(texture)
		var format := rd.texture_get_format(source)
		var data := PackedByteArray()
		# The native driver currently reads only mip 0 and ignores slice base
		# offsets in its synchronous readback path. Explicit copies into a
		# single-mip texture let this test verify actual GPU mip contents.
		for mip in range(format.mipmaps):
			var tf := RDTextureFormat.new()
			tf.format = format.format
			tf.width = maxi(1, format.width >> mip)
			tf.height = maxi(1, format.height >> mip)
			tf.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
			var copy := rd.texture_create(tf, RDTextureView.new())
			rd.texture_copy(source, copy, Vector3.ZERO, Vector3.ZERO, Vector3(tf.width, tf.height, 1), mip, 0, 0, 0)
			data.append_array(rd.texture_get_data(copy, 0))
			rd.free_rid(copy)
		result.data = data
	)
	RenderingServer.force_sync()
	return result.data

func add_glyphs(ts: TextServer, font: RID, size: int, first: int, last: int) -> Dictionary:
	var textures := {}
	for code in range(first, last):
		var glyph := ts.font_get_glyph_index(font, size, code, 0)
		var rid := ts.font_get_glyph_texture_rid(font, Vector2i(size, 0), glyph)
		if rid.is_valid():
			var index := ts.font_get_glyph_texture_idx(font, Vector2i(size, 0), glyph)
			textures[index] = rid
			# A second query must not generate another copy or upload.
			ts.font_get_glyph_texture_size(font, Vector2i(size, 0), glyph)
	return textures

func test_snapshots(ts: TextServer, mipmaps: bool) -> void:
	var label := "%s mipmaps=%s" % [ts.get_name(), mipmaps]
	var font := make_font(ts, mipmaps)
	var size := Vector2i(32, 0)
	var a := ts.font_get_glyph_index(font, size.x, 65, 0)
	var texture := ts.font_get_glyph_texture_rid(font, size, a)
	var index := ts.font_get_glyph_texture_idx(font, size, a)
	var initial := gpu_pixels(texture)
	check(same_pixels(initial, pixels(ts.font_get_texture_image(font, size, index), mipmaps), label + " first"), label + " first upload is immediate")
	var textures := add_glyphs(ts, font, size.x, 33, 127)
	if require_deferred:
		check(gpu_pixels(texture) == initial, label + " changes coalesce until pre-draw")
	else:
		check(gpu_pixels(texture) != initial, label + " other backend updates immediately")
	draw_frame()
	var valid := true
	for idx in textures:
		valid = same_pixels(gpu_pixels(textures[idx]), pixels(ts.font_get_texture_image(font, size, idx), mipmaps), label + " final") and valid
	check(valid, label + " final pixels and mip levels match every CPU atlas")
	check(ts.font_get_texture_image(font, size, index).get_format() == Image.FORMAT_LA8, label + " CPU mask atlas retains its serialized LA8 format")
	# Replace an atlas with different dimensions while its old texture has a
	# pending snapshot. The queued upload must not touch the replacement.
	add_glyphs(ts, font, size.x, 0x100, 0x130)
	var replacement := Image.create_empty(128, 64, false, Image.FORMAT_LA8)
	replacement.fill(Color(1.0, 1.0, 1.0, 0.25))
	ts.font_set_texture_image(font, size, index, replacement)
	var replaced_texture := ts.font_get_glyph_texture_rid(font, size, a)
	draw_frame()
	check(gpu_pixels(replaced_texture) == pixels(replacement, mipmaps), label + " replacing pending atlas preserves new dimensions and pixels")
	ts.free_rid(font)
	# Queue another upload, then remove all owning font/cache structures before
	# the flush. The queued job owns its texture and snapshot independently.
	var discarded := make_font(ts, mipmaps)
	add_glyphs(ts, discarded, size.x, 33, 96)
	ts.font_clear_size_cache(discarded)
	ts.free_rid(discarded)
	draw_frame()
	check(true, label + " pending upload survives freed size cache and font")

func test_first_frame(ts: TextServer) -> void:
	var font := make_font(ts)
	var a := ts.font_get_glyph_index(font, 32, 65, 0)
	ts.font_get_glyph_texture_rid(font, Vector2i(32, 0), a)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(96, 72)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	draw_frame() # Initialize an empty viewport first.
	var canvas := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(canvas, viewport.find_world_2d().canvas)
	var b := ts.font_get_glyph_index(font, 32, 66, 0)
	ts.font_draw_glyph(font, canvas, 32, Vector2(16, 48), b, Color.RED, 1.0)
	draw_frame() # The very first draw after requesting B.
	var image := viewport.get_texture().get_image()
	var red_pixels := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.5 and pixel.g < 0.01 and pixel.b < 0.01 and pixel.a > 0.5:
				red_pixels += 1
	check(red_pixels > 20, ts.get_name() + " newly added glyph is visible in its first rendered frame")
	RenderingServer.free_rid(canvas)
	viewport.queue_free()
	await get_tree().process_frame
	ts.free_rid(font)

func worker_glyphs(ts: TextServer, font: RID) -> void:
	for batch in range(4):
		add_glyphs(ts, font, 30, 33 + batch * 24, 57 + batch * 24)

func test_workers(ts: TextServer) -> void:
	var fonts: Array[RID] = []
	var jobs: Array[int] = []
	for i in range(4):
		var font := make_font(ts, i % 2 == 0)
		fonts.append(font)
		jobs.append(WorkerThreadPool.add_task(worker_glyphs.bind(ts, font)))
	var all_done := false
	while not all_done:
		await get_tree().process_frame
		all_done = true
		for job in jobs:
			all_done = all_done and WorkerThreadPool.is_task_completed(job)
	for job in jobs:
		WorkerThreadPool.wait_for_task_completion(job)
	draw_frame()
	var valid := true
	for i in fonts.size():
		var font := fonts[i]
		var textures := add_glyphs(ts, font, 30, 33, 129)
		for idx in textures:
			valid = same_pixels(gpu_pixels(textures[idx]), pixels(ts.font_get_texture_image(font, Vector2i(30, 0), idx), i % 2 == 0), ts.get_name() + " worker") and valid
		ts.free_rid(font)
	check(valid, ts.get_name() + " concurrent fonts retain complete immutable snapshots")

func test_cache_roundtrip(ts: TextServer) -> void:
	var font := make_font(ts)
	var size := Vector2i(32, 0)
	var glyphs: Array[int] = [ts.font_get_glyph_index(font, 32, 88, 0), ts.font_get_glyph_index(font, 32, 89, 0)]
	var mask := Image.create_empty(16, 16, false, Image.FORMAT_LA8)
	mask.fill(Color.WHITE)
	var color := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	color.fill(Color.YELLOW)
	for i in range(2):
		ts.font_set_texture_image(font, size, i, mask if i == 0 else color)
		ts.font_set_glyph_texture_idx(font, size, glyphs[i], i)
		ts.font_set_glyph_uv_rect(font, size, glyphs[i], Rect2(0, 0, 16, 16))
		ts.font_set_glyph_offset(font, size, glyphs[i], Vector2.ZERO)
		ts.font_set_glyph_size(font, size, glyphs[i], Vector2(16, 16))
	# Serialize only the data available through the public font-cache API, then
	# restore into another font. No new internal per-glyph flag may be required.
	var restored := make_font(ts)
	ts.font_get_glyph_index(restored, 32, 88, 0) # Initialize the FreeType face.
	for i in range(2):
		var source := ts.font_get_texture_image(font, size, i)
		var image := Image.create_from_data(source.get_width(), source.get_height(), source.has_mipmaps(), source.get_format(), source.get_data())
		ts.font_set_texture_image(restored, size, i, image)
		ts.font_set_glyph_texture_idx(restored, size, glyphs[i], i)
		ts.font_set_glyph_uv_rect(restored, size, glyphs[i], ts.font_get_glyph_uv_rect(font, size, glyphs[i]))
		ts.font_set_glyph_offset(restored, size, glyphs[i], ts.font_get_glyph_offset(font, size, glyphs[i]))
		ts.font_set_glyph_size(restored, size, glyphs[i], ts.font_get_glyph_size(font, size, glyphs[i]))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(72, 40)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var canvas := GlyphCanvas.new()
	canvas.ts = ts
	canvas.font = restored
	canvas.glyphs = glyphs
	viewport.add_child(canvas)
	canvas._draw()
	draw_frame()
	var image := viewport.get_texture().get_image()
	check(image.get_pixel(16, 16).is_equal_approx(Color.RED), ts.get_name() + " restored LA8 glyph respects text tint")
	check(image.get_pixel(40, 16).is_equal_approx(Color.YELLOW), ts.get_name() + " restored RGBA color glyph preserves intrinsic color")
	ts.font_set_modulate_color_glyphs(restored, true)
	RenderingServer.canvas_item_clear(canvas.get_canvas_item())
	canvas._draw()
	RenderingServer.force_draw(false)
	RenderingServer.force_sync()
	image = viewport.get_texture().get_image()
	check(image.get_pixel(40, 16).is_equal_approx(Color.RED), ts.get_name() + " explicit color-glyph modulation still works")
	viewport.queue_free()
	await get_tree().process_frame
	ts.free_rid(font)
	ts.free_rid(restored)

func benchmark(ts: TextServer) -> void:
	var times: Array[float] = []
	for trial in range(16):
		var begin := Time.get_ticks_usec()
		var font := make_font(ts, true)
		var textures := add_glyphs(ts, font, 32, 33, 127)
		RenderingServer.force_draw(false)
		for texture in textures.values():
			gpu_pixels(texture) # Includes queued transfer completion in timing.
		var elapsed := (Time.get_ticks_usec() - begin) / 1000.0
		if trial >= 4:
			times.append(elapsed)
		ts.free_rid(font)
		await get_tree().process_frame
	var ordered := times.duplicate()
	ordered.sort()
	print("FONT_BENCH ", JSON.stringify({"server": ts.get_name(), "milliseconds": times, "median_ms": (ordered[5] + ordered[6]) / 2.0, "glyphs": 94, "mipmaps": true}))

func _run() -> void:
	if font_data.is_empty():
		check(false, "--font must name a readable font")
	else:
		var tested := 0
		for i in TextServerManager.get_interface_count():
			var ts := TextServerManager.get_interface(i)
			if server_filter == "advanced" and ts.get_name().begins_with("Fallback"):
				continue
			if server_filter == "fallback" and not ts.get_name().begins_with("Fallback"):
				continue
			if not ts.has_feature(TextServer.FEATURE_FONT_DYNAMIC):
				continue
			tested += 1
			if benchmark_only:
				await benchmark(ts)
			else:
				await test_snapshots(ts, false)
				await test_snapshots(ts, true)
				await test_first_frame(ts)
				await test_workers(ts)
				await test_cache_roundtrip(ts)
		check(tested == (2 if server_filter == "all" else 1), "requested text servers were exercised: " + server_filter)
	print("FONT_TEST COMPLETE passed=%d failed=%d" % [passed, failed])
	get_tree().quit(1 if failed else 0)
