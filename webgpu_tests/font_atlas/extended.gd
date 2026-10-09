extends "res://main.gd"

var emoji_data: PackedByteArray
var svg_data: PackedByteArray

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--emoji="):
			emoji_data = FileAccess.get_file_as_bytes(arg.trim_prefix("--emoji="))
		if arg.begins_with("--svg="):
			svg_data = FileAccess.get_file_as_bytes(arg.trim_prefix("--svg="))
	super._ready()

func make_mode_font(ts: TextServer, mode: String) -> RID:
	var font := ts.create_font()
	ts.font_set_data(font, emoji_data if mode == "emoji" else (svg_data if mode == "svg" else font_data))
	ts.font_set_subpixel_positioning(font, TextServer.SUBPIXEL_POSITIONING_DISABLED)
	if mode == "msdf":
		ts.font_set_multichannel_signed_distance_field(font, true)
		ts.font_set_msdf_size(font, 48)
	if mode == "lcd":
		ts.font_set_antialiasing(font, TextServer.FONT_ANTIALIASING_LCD)
	return font

func render_mode(ts: TextServer, font: RID, glyph: int, size: int) -> Image:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 96)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var canvas := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(canvas, viewport.find_world_2d().canvas)
	ts.font_draw_glyph(font, canvas, size, Vector2(16, 72), glyph, Color.RED, 1.0)
	draw_frame()
	var image := viewport.get_texture().get_image()
	RenderingServer.free_rid(canvas)
	viewport.queue_free()
	return image

func colored_pixels(image: Image, mode: String) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.a < 0.5:
				continue
			if mode == "svg" and c.b > 0.5 and c.r < 0.1:
				count += 1
			elif mode == "emoji" and c.r > 0.5 and c.g > 0.25 and c.b < 0.3:
				count += 1
			elif mode in ["lcd", "msdf"] and c.r > 0.5 and c.g < 0.05 and c.b < 0.05:
				count += 1
	return count

func test_mode(ts: TextServer, mode: String) -> void:
	var font := make_mode_font(ts, mode)
	var size := Vector2i(48, 0)
	var codes := [0x1f600, 0x1f604] if mode == "emoji" else [65, 66]
	var a := ts.font_get_glyph_index(font, size.x, codes[0], 0)
	var b := ts.font_get_glyph_index(font, size.x, codes[1], 0)
	var texture := ts.font_get_glyph_texture_rid(font, size, a)
	var index := ts.font_get_glyph_texture_idx(font, size, a)
	var label := ts.get_name() + " " + mode
	check(a != 0 and b != 0 and texture.is_valid(), label + " source glyphs exist")
	if not texture.is_valid():
		ts.free_rid(font)
		return
	var initial := gpu_pixels(texture)
	var first_image := ts.font_get_texture_image(font, size, index)
	check(first_image.get_format() == Image.FORMAT_RGBA8 and initial == pixels(first_image), label + " first RGBA atlas upload is immediate")
	ts.font_get_glyph_texture_rid(font, size, b)
	check(gpu_pixels(texture) == initial, label + " second glyph upload waits for pre-draw")
	# render_mode submits the next draw; it must include the newly requested B.
	var rendered := render_mode(ts, font, b, size.x)
	var atlas := ts.font_get_texture_image(font, size, index)
	check(gpu_pixels(texture) == pixels(atlas), label + " final GPU atlas matches CPU pixels")
	check(colored_pixels(rendered, mode) > 30, label + " first rendered glyph has correct intrinsic color or text tint")
	# Restore all public cache state, including the mode flag for LCD/MSDF.
	var restored := make_mode_font(ts, mode)
	ts.font_get_glyph_index(restored, size.x, codes[1], 0)
	var b_index := ts.font_get_glyph_texture_idx(font, size, b)
	var source := ts.font_get_texture_image(font, size, b_index)
	var copy := Image.create_from_data(source.get_width(), source.get_height(), source.has_mipmaps(), source.get_format(), source.get_data())
	ts.font_set_texture_image(restored, size, b_index, copy)
	# The public cache list includes LCD-layout/subpixel bits. Setters accept
	# these cache keys, while render calls accept the underlying glyph index.
	for cache_key in ts.font_get_glyph_list(font, size):
		if (cache_key & 0xffffff) != b:
			continue
		ts.font_set_glyph_texture_idx(restored, size, cache_key, b_index)
		ts.font_set_glyph_uv_rect(restored, size, cache_key, ts.font_get_glyph_uv_rect(font, size, cache_key))
		ts.font_set_glyph_offset(restored, size, cache_key, ts.font_get_glyph_offset(font, size, cache_key))
		ts.font_set_glyph_size(restored, size, cache_key, ts.font_get_glyph_size(font, size, cache_key))
	var roundtrip := render_mode(ts, restored, b, size.x)
	check(roundtrip.get_data() == rendered.get_data(), label + " public cache roundtrip preserves rendered pixels")
	if mode in ["emoji", "svg"]:
		ts.font_set_modulate_color_glyphs(restored, true)
		var modulated := render_mode(ts, restored, b, size.x)
		check(colored_pixels(modulated, mode) == 0, label + " explicit modulation changes intrinsic color")
	var safe_name := ts.get_name().replace(" ", "_").replace("/", "_") + "-" + mode
	rendered.save_png("user://" + safe_name + ".png")
	print("FONT_EXT_IMAGE ", OS.get_user_data_dir().path_join(safe_name + ".png"))
	ts.free_rid(font)
	ts.free_rid(restored)
	await get_tree().process_frame

func _run() -> void:
	if font_data.is_empty() or emoji_data.is_empty() or svg_data.is_empty():
		check(false, "all source fonts supplied")
	else:
		var tested := 0
		for i in TextServerManager.get_interface_count():
			var ts := TextServerManager.get_interface(i)
			if not ts.has_feature(TextServer.FEATURE_FONT_DYNAMIC):
				continue
			tested += 1
			for mode in ["lcd", "msdf", "emoji", "svg"]:
				await test_mode(ts, mode)
		check(tested == 2, "advanced and fallback servers tested")
	print("FONT_TEST COMPLETE passed=%d failed=%d" % [passed, failed])
	get_tree().quit(1 if failed else 0)
