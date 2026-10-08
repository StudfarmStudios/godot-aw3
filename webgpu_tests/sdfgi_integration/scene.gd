extends SceneTree

var directory := ""
var requested_cascades := 4
var debug_capture := false
var use_occlusion := true
var benchmark_frames := 0
var scroll_frames := 20
var rebuild_scrolled := false
var metrics := {}
var environment: Environment
var geometry_root: Node3D
var viewport: SubViewport
var draw_count := 0

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--debug-capture": debug_capture = true
		if argument == "--rebuild-scrolled": rebuild_scrolled = true
		if argument == "--no-occlusion": use_occlusion = false
		if argument.begins_with("--benchmark-frames="): benchmark_frames = int(argument.trim_prefix("--benchmark-frames="))
		if argument.begins_with("--scroll-frames="): scroll_frames = int(argument.trim_prefix("--scroll-frames="))
		if argument.begins_with("--cascades="): requested_cascades = int(argument.trim_prefix("--cascades="))
		if argument.begins_with("--fixture-dir="):
			directory = argument.trim_prefix("--fixture-dir=")
	RenderingServer.frame_post_draw.connect(_frame_drawn)
	call_deferred("_run")

func box(size: Vector3, position: Vector3, color: Color, emission: bool = false) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = position
	node.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	if emission:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 6.0
	node.material_override = material
	geometry_root.add_child(node)

func _frame_drawn() -> void:
	draw_count += 1

func frames(count: int) -> void:
	for frame in count:
		await process_frame
		var previous := draw_count
		RenderingServer.force_draw(false, 1.0 / 60.0)
		RenderingServer.force_sync()
		var deadline := Time.get_ticks_msec() + 5000
		while draw_count == previous and Time.get_ticks_msec() < deadline:
			await process_frame
		if draw_count == previous:
			push_error("SDFGI_SCENE FAIL frame handoff timed out")

func capture(name: String) -> Image:
	var image := viewport.get_texture().get_image()
	image.save_png(directory.path_join(name + ".png"))
	return image

func memory_metrics() -> Dictionary:
	var result := {}
	var monitors := {"video_bytes": Performance.RENDER_VIDEO_MEM_USED, "texture_bytes": Performance.RENDER_TEXTURE_MEM_USED, "buffer_bytes": Performance.RENDER_BUFFER_MEM_USED}
	for label in monitors:
		var value := Performance.get_monitor(monitors[label])
		# Some driver counters wrap during startup. Preserve that evidence rather
		# than saturating an int and reporting a fictitious negative delta.
		if not is_finite(value) or value < 0.0 or value >= 9.0e18:
			result[label] = null
			result[label + "_invalid_raw"] = str(value)
		else:
			result[label] = int(value)
	return result

func pipeline_count() -> int:
	var result := 0
	for monitor in [Performance.PIPELINE_COMPILATIONS_CANVAS, Performance.PIPELINE_COMPILATIONS_MESH, Performance.PIPELINE_COMPILATIONS_SURFACE, Performance.PIPELINE_COMPILATIONS_DRAW, Performance.PIPELINE_COMPILATIONS_SPECIALIZATION]:
		result += int(Performance.get_monitor(monitor))
	return result

func sample_stats(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {"samples": 0}
	values.sort()
	var total := 0.0
	for value in values: total += value
	return {"samples": values.size(), "median_ms": values[values.size() / 2], "p95_ms": values[mini(values.size() - 1, int(values.size() * 0.95))], "mean_ms": total / values.size()}

func settle_pipelines(label: String) -> void:
	var quiet_frames := 0
	var previous := pipeline_count()
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 60000:
		await frames(1)
		var current := pipeline_count()
		var pending := RenderingServer.get_pending_pipeline_compilation_count()
		quiet_frames = quiet_frames + 1 if current == previous and pending == 0 else 0
		previous = current
		if quiet_frames >= 10: break
	metrics[label + "_pipeline_settle"] = {"quiet_frames": quiet_frames, "pending": RenderingServer.get_pending_pipeline_compilation_count(), "pipeline_count": previous, "milliseconds": Time.get_ticks_msec() - start}
	if quiet_frames < 10:
		push_error("SDFGI_SCENE FAIL pipeline compilation did not settle: " + label)

func benchmark(label: String) -> void:
	if benchmark_frames == 0: return
	await settle_pipelines(label)
	var previous := pipeline_count()
	# Readback drains submitted GPU work; neither sample includes earlier work.
	viewport.get_texture().get_image()
	var start := Time.get_ticks_usec()
	var cpu_samples: Array[float] = []
	var gpu_samples: Array[float] = []
	for frame in benchmark_frames:
		await frames(1)
		var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
		if cpu_ms > 0: cpu_samples.append(cpu_ms)
		if gpu_ms > 0: gpu_samples.append(gpu_ms)
	viewport.get_texture().get_image()
	metrics[label] = {"frames": benchmark_frames, "total_ms": (Time.get_ticks_usec() - start) / 1000.0, "pipeline_count_start": previous, "pipeline_count_end": pipeline_count(), "pending_end": RenderingServer.get_pending_pipeline_compilation_count(), "viewport_cpu": sample_stats(cpu_samples), "viewport_gpu": sample_stats(gpu_samples)}

func _run() -> void:
	RenderingServer.render_loop_enabled = false
	viewport = SubViewport.new()
	viewport.size = Vector2i(128,128)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	if benchmark_frames > 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	geometry_root = Node3D.new()
	viewport.add_child(geometry_root)
	var world := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02,0.02,0.02)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.sdfgi_cascades = requested_cascades
	environment.sdfgi_min_cell_size = 0.2
	environment.sdfgi_read_sky_light = false
	environment.sdfgi_use_occlusion = use_occlusion
	environment.sdfgi_energy = 1.0
	environment.sdfgi_bounce_feedback = 0.0
	world.environment = environment
	geometry_root.add_child(world)
	box(Vector3(10,0.2,10),Vector3(0,-0.1,0),Color(0.7,0.7,0.7))
	box(Vector3(10,4,0.2),Vector3(0,2,-3),Color(0.7,0.7,0.7))
	box(Vector3(0.2,4,8),Vector3(-3,2,0),Color(0.7,0.7,0.7))
	box(Vector3(1.5,1.5,1.5),Vector3(0,0.75,0),Color(1,0.04,0.02),true)
	var camera := Camera3D.new()
	camera.position = Vector3(4,3.5,5)
	geometry_root.add_child(camera)
	camera.look_at(Vector3(0,0.7,0))
	camera.current = true
	await frames(5)
	await settle_pipelines("disabled")
	metrics["disabled_memory"] = memory_metrics()
	await benchmark("disabled_timing")
	var baseline := capture("disabled")
	environment.sdfgi_enabled = true
	await frames(45)
	await settle_pipelines("enabled")
	await frames(10)
	metrics["enabled_memory"] = memory_metrics()
	await benchmark("enabled_timing")
	var lit := capture("enabled")
	if debug_capture:
		viewport.debug_draw = Viewport.DEBUG_DRAW_SDFGI
		await frames(3)
		capture("debug-sdfgi")
		viewport.debug_draw = Viewport.DEBUG_DRAW_SDFGI_PROBES
		await frames(3)
		capture("debug-probes")
		viewport.debug_draw = Viewport.DEBUG_DRAW_GI_BUFFER
		await frames(3)
		capture("debug-gi-buffer")
		viewport.debug_draw = Viewport.DEBUG_DRAW_NORMAL_BUFFER
		await frames(3)
		capture("debug-normal-buffer")
		viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	# Move far enough to exercise incremental cascade scrolling, then settle.
	camera.position += Vector3(2.1,0,0)
	camera.look_at(Vector3(0,0.7,0))
	await frames(scroll_frames)
	await settle_pipelines("scrolled")
	var scrolled := capture("scrolled")
	if debug_capture:
		viewport.debug_draw = Viewport.DEBUG_DRAW_SDFGI
		await frames(3)
		capture("scrolled-debug-sdfgi")
		viewport.debug_draw = Viewport.DEBUG_DRAW_SDFGI_PROBES
		await frames(3)
		capture("scrolled-debug-probes")
		viewport.debug_draw = Viewport.DEBUG_DRAW_GI_BUFFER
		await frames(3)
		capture("scrolled-debug-gi-buffer")
		viewport.debug_draw = Viewport.DEBUG_DRAW_NORMAL_BUFFER
		await frames(3)
		capture("scrolled-debug-normal-buffer")
		viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	environment.sdfgi_enabled = false
	await frames(3)
	metrics["freed_memory"] = memory_metrics()
	var scrolled_baseline := capture("scrolled-disabled")
	if rebuild_scrolled:
		environment.sdfgi_enabled = true
		await frames(45)
		await settle_pipelines("rebuilt")
		await frames(10)
		capture("scrolled-rebuilt")
	var affected := 0
	var increase := 0.0
	for y in 128:
		for x in 128:
			var before := baseline.get_pixel(x,y)
			var after := lit.get_pixel(x,y)
			# Exclude the already bright emissive cube itself.
			if before.r < 0.2:
				var delta: float = after.r - before.r
				if delta > 0.025:
					affected += 1
					increase += delta
	var scrolled_affected := 0
	for y in 128:
		for x in 128:
			var before := scrolled_baseline.get_pixel(x,y)
			if before.r < 0.2 and scrolled.get_pixel(x,y).r - before.r > 0.025:
				scrolled_affected += 1
	var passed := affected > 100 and increase > 10.0 and scrolled_affected > 100
	print("SDFGI_SCENE %s cascades=%d affected=%d red_increase=%f scrolled_affected=%d" % ["PASS" if passed else "FAIL",requested_cascades,affected,increase,scrolled_affected])
	var file := FileAccess.open(directory.path_join("scene-metrics.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "  "))
	file.close()
	quit(0 if passed else 1)
