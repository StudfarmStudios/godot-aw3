extends SceneTree

# Native Dawn with TimestampQuery support. Reject the old unsafe standalone
# WriteTimestamp path; real nonzero monotonic readbacks must arrive across frames.
var rd: RenderingDevice
var texture: RID
var framebuffer: RID
var valid_samples := 0
var last_frame := -1
var order_failed := false
var last_gpu_begin := 0

func _initialize() -> void:
	call_deferred("_run")

func _setup() -> void:
	rd = RenderingServer.get_rendering_device()
	var tf := RDTextureFormat.new()
	tf.width = 64
	tf.height = 64
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
	texture = rd.texture_create(tf, RDTextureView.new())
	framebuffer = rd.framebuffer_create([texture])

func _record() -> void:
	var captured_frame := rd.get_captured_timestamps_frame()
	if captured_frame != last_frame:
		var begin := 0
		var end := 0
		for i in rd.get_captured_timestamps_count():
			if rd.get_captured_timestamp_name(i) == "test_begin":
				begin = rd.get_captured_timestamp_gpu_time(i)
			if rd.get_captured_timestamp_name(i) == "test_end":
				end = rd.get_captured_timestamp_gpu_time(i)
		if begin > 0 and end > 0:
			order_failed = order_failed or end < begin or begin <= last_gpu_begin
			last_gpu_begin = begin
			valid_samples += 1
		last_frame = captured_frame
	rd.capture_timestamp("test_begin")
	rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0, [Color.CORNFLOWER_BLUE])
	rd.draw_list_end()
	rd.capture_timestamp("test_end")

func _cleanup() -> void:
	rd.free_rid(framebuffer)
	rd.free_rid(texture)

func _run() -> void:
	RenderingServer.call_on_render_thread(_setup)
	await process_frame
	for iteration in 60:
		await process_frame
		RenderingServer.call_on_render_thread(_record)
		await RenderingServer.frame_post_draw
	var passed := valid_samples >= 10 and not order_failed
	print("TIMESTAMP_TEST " + JSON.stringify({"passed": passed, "valid_samples": valid_samples, "order_failed": order_failed}))
	RenderingServer.call_on_render_thread(_cleanup)
	await process_frame
	quit(0 if passed else 1)
