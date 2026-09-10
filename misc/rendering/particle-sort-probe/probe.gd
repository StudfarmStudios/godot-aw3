extends SceneTree

# Exercise the production sorting shader with allocated canary padding. A bounds
# regression can change the canaries, but never writes outside this allocation.
const COUNTS = [1, 2, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 2049, 4096, 4097, 5000, 8191, 8192, 8193]
const PATTERNS = ["reverse", "scrambled", "duplicates"]


func _initialize():
	call_deferred("run")


func key_for(index: int, count: int, pattern: String) -> float:
	match pattern:
		"reverse":
			return float(count - index)
		"scrambled":
			return float((index * 97 + 19) % count)
		_:
			return float(index % 17)


func sort_buffer(rd: RenderingDevice, pipelines: Array[RID], uniform_set: RID, count: int):
	# Match SortEffects::sort_buffer(), including its rounded-up merge dispatch.
	var params = PackedByteArray()
	params.resize(32)
	params.encode_u32(0, count)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipelines[0])
	rd.compute_list_bind_uniform_set(list, uniform_set, 1)
	rd.compute_list_set_push_constant(list, params, params.size())
	rd.compute_list_dispatch(list, (count + 511) / 512, 1, 1)
	var presorted = 512
	while presorted < count:
		rd.compute_list_add_barrier(list)
		rd.compute_list_bind_compute_pipeline(list, pipelines[1])
		var rounded_count = presorted
		while rounded_count < count:
			rounded_count *= 2
		var merge_size = presorted * 2
		var merge_sub_size = presorted
		while merge_sub_size > 256:
			params.encode_s32(16, merge_sub_size)
			params.encode_s32(20, 2 * merge_sub_size - 1 if merge_sub_size == presorted else merge_sub_size)
			params.encode_s32(24, -1 if merge_sub_size == presorted else 1)
			params.encode_s32(28, 0)
			rd.compute_list_set_push_constant(list, params, params.size())
			rd.compute_list_dispatch(list, rounded_count / 512, 1, 1)
			rd.compute_list_add_barrier(list)
			merge_sub_size /= 2
		rd.compute_list_bind_compute_pipeline(list, pipelines[2])
		rd.compute_list_set_push_constant(list, params, params.size())
		rd.compute_list_dispatch(list, rounded_count / 512, 1, 1)
		presorted = merge_size
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func run():
	var rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("This probe requires a renderer with local RenderingDevice support.")
		quit(2)
		return
	var shader_path = ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/effects/sort.glsl")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sort-source="):
			shader_path = arg.trim_prefix("--sort-source=")
	var shader_text = FileAccess.get_file_as_string(shader_path).replace("#[compute]", "")
	var shaders: Array[RID] = []
	var pipelines: Array[RID] = []
	for mode in ["MODE_SORT_BLOCK", "MODE_SORT_STEP", "MODE_SORT_INNER"]:
		var source = RDShaderSource.new()
		source.source_compute = shader_text.replace("#VERSION_DEFINES", "#define " + mode)
		var spirv = rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			quit(2)
			return
		var shader = rd.shader_create_from_spirv(spirv)
		shaders.append(shader)
		pipelines.append(rd.compute_pipeline_create(shader))
	var failures = 0
	for count in COUNTS:
		var capacity = 512
		while capacity < count:
			capacity *= 2
		for pattern in PATTERNS:
			var input = PackedByteArray()
			input.resize(capacity * 8)
			for index in range(capacity):
				input.encode_float(index * 8, key_for(index, count, pattern) if index < count else -float(index + 1))
				input.encode_float(index * 8 + 4, float(index))
			var buffer = rd.storage_buffer_create(input.size(), input)
			var uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding = 0
			uniform.add_id(buffer)
			var uniform_set = rd.uniform_set_create([uniform], shaders[0], 1)
			sort_buffer(rd, pipelines, uniform_set, count)
			var result = rd.buffer_get_data(buffer)
			var padding_ok = result.slice(count * 8) == input.slice(count * 8)
			var order_ok = true
			var pairs_ok = true
			var seen = {}
			var previous = -INF
			for index in range(count):
				var key = result.decode_float(index * 8)
				var id = int(result.decode_float(index * 8 + 4))
				order_ok = order_ok and key >= previous
				pairs_ok = pairs_ok and id >= 0 and id < count and not seen.has(id) and key == key_for(id, count, pattern)
				seen[id] = true
				previous = key
			if not (padding_ok and order_ok and pairs_ok):
				failures += 1
				print("SORT_FAIL count=%d pattern=%s padding=%s order=%s pairs=%s" % [count, pattern, padding_ok, order_ok, pairs_ok])
			rd.free_rid(uniform_set)
			rd.free_rid(buffer)
	for pipeline in pipelines:
		rd.free_rid(pipeline)
	for shader in shaders:
		rd.free_rid(shader)
	rd.free()
	print("SORT_PROBE_DONE cases=%d failures=%d" % [COUNTS.size() * PATTERNS.size(), failures])
	quit(0 if failures == 0 else 1)
