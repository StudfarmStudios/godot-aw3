extends SceneTree

# Submission + GPU completion microbenchmark, not a game frame-time claim.
# A local device avoids surface presentation/VSync; alternate binaries.
var rd: RenderingDevice
var texture: RID
var framebuffer: RID
var frame := 0
var color_mode := false

func _initialize() -> void:
	call_deferred("_run")

func _setup() -> void:
	rd = RenderingServer.create_local_rendering_device()
	var tf := RDTextureFormat.new()
	tf.width = 512
	tf.height = 512
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if color_mode else RenderingDevice.DATA_FORMAT_D32_SFLOAT
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT if color_mode else RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
	texture = rd.texture_create(tf, RDTextureView.new())
	framebuffer = rd.framebuffer_create([texture])

func _record() -> void:
	frame += 1
	rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color.BLACK] if color_mode else [], 0.0)
	rd.draw_list_end()
	for i in 128:
		var value := float((i + frame) % 8) * 0.125
		rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL,
			[Color(value * 2.0, value, -value, 1.0)] if color_mode else [], value, 0,
			Rect2((i % 8) * 64, ((i >> 3) % 8) * 64, 64, 64))
		rd.draw_list_end()

func _cleanup() -> void:
	rd.free_rid(framebuffer)
	rd.free_rid(texture)
	rd.free()

func _run() -> void:
	color_mode = OS.get_cmdline_user_args().has("--bench-color")
	_setup()
	var samples: Array[float] = []
	for iteration in 150:
		var begin := Time.get_ticks_usec()
		_record()
		rd.submit()
		rd.sync()
		if iteration >= 30:
			samples.append(float(Time.get_ticks_usec() - begin) / 1000.0)
	samples.sort()
	print("CLEAR_BENCH " + JSON.stringify({"mode": "color" if color_mode else "depth", "clears_per_batch": 128,
		"batches": samples.size(), "median_ms": samples[60], "p90_ms": samples[108], "adapter": rd.get_device_name()}))
	_cleanup()
	quit()
