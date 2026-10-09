extends SceneTree

var rd: RenderingDevice
var owned: Array[RID] = []
var directory := ""
var shaders: Array[RID] = []
var pipelines: Array[RID] = []
var cascade_count := 0
var checks := 0
var failed := 0
var sample_set: RID
var query_count := 0
var queries := PackedByteArray()
var results: RID
var texture_set: RID
var clear_set: RID
var cleared: Array[int] = []

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture-dir="):
			directory = argument.trim_prefix("--fixture-dir=")
	call_deferred("_run")

func own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	return rid

func uniform(kind: int, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = kind
	u.binding = binding
	u.add_id(rid)
	return u

func setup(count: int) -> bool:
	cascade_count = count
	cleared.clear()
	for name in ["fill", "sample", "clear"]:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(directory.path_join(name + ".comp"))
		var spirv := rd.shader_compile_spirv_from_source(source, false)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			return false
		var shader := own(rd.shader_create_from_spirv(spirv))
		shaders.append(shader)
		pipelines.append(own(rd.compute_pipeline_create(shader)))
	var textures: Array[RID] = []
	for format in [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM]:
		var tf := RDTextureFormat.new()
		tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
		tf.format = format
		tf.width = 256 if count > 1 else 128
		tf.height = 256 if count > 2 else 128
		tf.depth = 128 if count <= 4 else 256
		tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		textures.append(own(rd.texture_create(tf, RDTextureView.new())))
	var images: Array[RDUniform] = []
	for i in 3: images.append(uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, i + 1, textures[i]))
	texture_set = own(rd.uniform_set_create(images, shaders[0], 0))
	clear_set = own(rd.uniform_set_create(images, shaders[2], 0))
	var uv: Array[Vector3] = [Vector3(-0.2, -0.2, -0.2), Vector3.ZERO, Vector3.ONE * 0.001, Vector3.ONE / 256, Vector3.ONE * 0.2, Vector3(0.25,0.75,0.37), Vector3.ONE * 0.5, Vector3.ONE * 0.998, Vector3.ONE, Vector3.ONE * 1.2]
	queries.clear()
	queries.resize(count * uv.size() * 16)
	query_count = count * uv.size()
	for cascade in count:
		for j in uv.size():
			var offset: int = (cascade * uv.size() + j) * 16
			queries.encode_float(offset, cascade)
			queries.encode_float(offset + 4, uv[j].x)
			queries.encode_float(offset + 8, uv[j].y)
			queries.encode_float(offset + 12, uv[j].z)
	var query_buffer := own(rd.storage_buffer_create(queries.size(), queries))
	results = own(rd.storage_buffer_create(query_count * 3 * 16))
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler := own(rd.sampler_create(state))
	var samples: Array[RDUniform] = [uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,query_buffer), uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,2,results), uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER,6,sampler)]
	for i in 3: samples.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE,[100,110,130][i],textures[i]))
	sample_set = own(rd.uniform_set_create(samples,shaders[1],0))
	return sample_set.is_valid() and clear_set.is_valid() and texture_set.is_valid()

func dispatch(operation: int, cascade: int = 0) -> void:
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands,pipelines[operation])
	rd.compute_list_bind_uniform_set(commands,[texture_set,sample_set,clear_set][operation],0)
	if operation == 2:
		var pc := PackedByteArray()
		pc.resize(48)
		pc.encode_s32(12,128)
		pc.encode_s32(40,cascade)
		rd.compute_list_set_push_constant(commands,pc,pc.size())
	if operation == 0: rd.compute_list_dispatch(commands,64 if cascade_count > 1 else 32,64 if cascade_count > 2 else 32,32 if cascade_count <= 4 else 64)
	elif operation == 1: rd.compute_list_dispatch(commands,(query_count + 63) / 64,1,1)
	else: rd.compute_list_dispatch(commands,32,32,32)
	rd.compute_list_end()

func check(label: String) -> void:
	dispatch(1)
	rd.submit()
	rd.sync()
	var actual := rd.buffer_get_data(results)
	var wrong := 0
	var max_error := 0.0
	for query in query_count:
		var cascade := int(queries.decode_float(query * 16))
		var expected := PackedFloat32Array([float(cascade + 1) / 16.0,0,0,0])
		for axis in 3: expected[axis + 1] = (clampf(queries.decode_float(query * 16 + 4 + axis * 4) * 128.0,0.5,127.5) - 0.5) / 127.0
		if cleared.has(cascade): expected.fill(0)
		for field in 3:
			for component in 4:
				var value: float = expected[component]
				var error: float = absf(actual.decode_float((query * 3 + field) * 16 + component * 4) - value)
				max_error = maxf(max_error,error)
				if error > 0.005: wrong += 1
	checks += 1
	if wrong: failed += 1
	print("SDFGI_ATLAS %s cascades=%d %s wrong=%d max_error=%f" % ["FAIL" if wrong else "PASS",cascade_count,label,wrong,max_error])

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		quit(2)
		return
	for count in range(1,9):
		if not setup(count):
			quit(2)
			return
		dispatch(0)
		check("all tiles and clamped edges")
		for cascade in [0,count - 1,mini(2,count - 1)]:
			dispatch(2,cascade)
			cleared.append(cascade)
			check("clear tile %d preserves others" % cascade)
		for index in range(owned.size()-1,-1,-1): rd.free_rid(owned[index])
		owned.clear()
		shaders.clear()
		pipelines.clear()
	rd.free()
	print("SDFGI_ATLAS COMPLETE checks=%d failed=%d" % [checks,failed])
	quit(0 if failed == 0 else 1)
