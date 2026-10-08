extends SceneTree

var directory := ""
var no_filter := false
var owned: Array[RID] = []
var rd: RenderingDevice

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture-dir="): directory = argument.trim_prefix("--fixture-dir=")
		if argument == "--webgpu-no-float32-filterable": no_filter = true
	call_deferred("_run")

func own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	return rid

func uniform(kind: int, binding: int, rid: RID) -> RDUniform:
	var result := RDUniform.new()
	result.uniform_type = kind
	result.binding = binding
	result.add_id(rid)
	return result

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	var texels := PackedFloat32Array()
	for i in 16: texels.append(0.125 + float(i) * 0.03125)
	var format := RDTextureFormat.new()
	format.width = 4
	format.height = 4
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var texture := own(rd.texture_create(format, RDTextureView.new(), [texels.to_byte_array()]))
	var state := RDSamplerState.new()
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler := own(rd.sampler_create(state))
	var coordinates := PackedFloat32Array()
	var expected := PackedFloat32Array()
	for y in [-0.25, 0.0, 0.125, 0.2499, 0.25, 0.5, 0.9999, 1.0, 1.25]:
		for x in [-0.25, 0.0, 0.125, 0.2499, 0.25, 0.5, 0.9999, 1.0, 1.25]:
			coordinates.append(x)
			coordinates.append(y)
			expected.append(texels[clampi(floori(y * 4), 0, 3) * 4 + clampi(floori(x * 4), 0, 3)])
	var input := own(rd.storage_buffer_create(coordinates.size() * 4, coordinates.to_byte_array()))
	var output := own(rd.storage_buffer_create(expected.size() * 4))
	var shaders := ["lookup"] if no_filter else ["lookup", "nearest"]
	var failed := 0
	var checks := 0
	for variant in shaders:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(directory.path_join(variant + ".comp"))
		var spirv := rd.shader_compile_spirv_from_source(source, false)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			quit(2)
			return
		var shader := own(rd.shader_create_from_spirv(spirv))
		var pipeline := own(rd.compute_pipeline_create(shader))
		var bindings := own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 0, texture), uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 1, sampler), uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, input), uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, output)], shader, 0))
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands, pipeline)
		rd.compute_list_bind_uniform_set(commands, bindings, 0)
		rd.compute_list_dispatch(commands, expected.size(), 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var values := rd.buffer_get_data(output).to_float32_array()
		for i in expected.size():
			checks += 1
			if absf(values[i] - expected[i]) > 0.000001:
				failed += 1
				print("NORMAL_LUT %s index=%d expected=%f actual=%f" % [variant, i, expected[i], values[i]])
	for index in range(owned.size() - 1, -1, -1): rd.free_rid(owned[index])
	rd.free()
	print("NORMAL_LUT COMPLETE checks=%d failed=%d" % [checks, failed])
	quit(0 if failed == 0 else 1)
