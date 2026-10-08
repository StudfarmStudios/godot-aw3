extends SceneTree

var rd: RenderingDevice
var resources: Array[RID] = []
var sampler: RID
var scene_data: RID
var config: Dictionary
var stages: Array[Dictionary] = []

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--bench-config="):
			config = JSON.parse_string(FileAccess.get_file_as_string(argument.trim_prefix("--bench-config=")))
	call_deferred("_run")

func _own(resource: RID) -> RID:
	if resource.is_valid(): resources.append(resource)
	return resource

func _texture(name: String) -> RID:
	var formats := {"r32":RenderingDevice.DATA_FORMAT_R32_SFLOAT,"rgba8":RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,"rgba16":RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,"r8":RenderingDevice.DATA_FORMAT_R8_UNORM}
	var format := RDTextureFormat.new()
	format.format = formats[name]
	format.width = 4
	format.height = 4
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _own(rd.texture_create(format, RDTextureView.new()))

func _uniforms(bindings: Array) -> Array[RDUniform]:
	var result: Array[RDUniform] = []
	for index in bindings.size():
		var parts: PackedStringArray = bindings[index].split(":")
		var uniform := RDUniform.new()
		uniform.binding = index
		if parts[0] == "u":
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
			uniform.add_id(scene_data)
		else:
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE if parts[0] == "s" else RenderingDevice.UNIFORM_TYPE_IMAGE
			if parts[0] == "s": uniform.add_id(sampler)
			uniform.add_id(_texture(parts[1]))
		result.append(uniform)
	return result

func _drain() -> void:
	# Deferred frees and device submission are outside every measured interval.
	for index in 3:
		rd.submit()
		rd.sync()

func _batch(stage: Dictionary, count: int) -> Dictionary:
	var shader_us := 0
	var fresh_uniform_us := 0
	var reused_uniform_us := 0
	var owned: Array[RID] = []
	var valid := true
	for index in count:
		var start := Time.get_ticks_usec()
		var shader := rd.shader_create_from_spirv(stage.spirv, stage.name)
		shader_us += Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		var uniforms := rd.uniform_set_create(stage.uniforms, shader, 0)
		fresh_uniform_us += Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		var reused := rd.uniform_set_create(stage.uniforms, stage.seed, 0)
		reused_uniform_us += Time.get_ticks_usec() - start
		valid = valid and shader.is_valid() and uniforms.is_valid() and reused.is_valid()
		owned.append_array([shader, uniforms, reused])
	for index in range(owned.size() - 1, -1, -1): rd.free_rid(owned[index])
	_drain()
	return {"valid":valid,"iterations":count,"shader_create_us":shader_us,"fresh_layout_uniform_us":fresh_uniform_us,"reused_layout_uniform_us":reused_uniform_us}

func _run() -> void:
	if config.is_empty():
		push_error("LAYOUT_BENCH missing configuration")
		quit(1)
		return
	rd = RenderingServer.create_local_rendering_device()
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = _own(rd.sampler_create(state))
	scene_data = _own(rd.uniform_buffer_create(416))
	# Compile GLSL, create resources, and seed source-analysis/WGSL caches before timing.
	for entry: Dictionary in config.stages:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(entry.path)
		var spirv := rd.shader_compile_spirv_from_source(source, false)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			quit(1)
			return
		var stage := {"name":entry.name,"spirv":spirv,"uniforms":_uniforms(entry.bindings),"spirv_bytes":spirv.bytecode_compute.size()}
		stage.seed = _own(rd.shader_create_from_spirv(spirv, entry.name))
		_own(rd.uniform_set_create(stage.uniforms, stage.seed, 0))
		stages.append(stage)
	for stage: Dictionary in stages:
		if not _batch(stage, 3).valid:
			push_error("LAYOUT_BENCH invalid warmup")
			quit(1)
			return
	var results: Array[Dictionary] = []
	var valid := true
	for batch in int(config.batches):
		for stage: Dictionary in stages:
			var result := _batch(stage, config.iterations)
			result.stage = stage.name
			result.batch = batch
			result.spirv_bytes = stage.spirv_bytes
			valid = valid and result.valid
			results.append(result)
	for index in range(resources.size() - 1, -1, -1): rd.free_rid(resources[index])
	_drain()
	rd.free()
	print("LAYOUT_BENCH_RESULT ", JSON.stringify({"passed":valid,"mode":config.mode,"batches":config.batches,"iterations":config.iterations,"samples":results}))
	quit(0 if valid else 1)
