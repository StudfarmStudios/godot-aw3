extends SceneTree
var directory := ""
var passed := 0
var failed := 0
func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--literal-directory="): directory = argument.trim_prefix("--literal-directory=")
	call_deferred("_run")
func _check(ok: bool, label: String, detail: Variant = "") -> void:
	passed += int(ok)
	failed += int(not ok)
	print("SAMPLED_LITERALS %s %s %s" % ["PASS" if ok else "FAIL", label, detail])
func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	for label: String in ["fmax", "composite", "switch", "debug"]:
		var spirv := RDShaderSPIRV.new()
		spirv.set_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE, FileAccess.get_file_as_bytes(directory.path_join(label + ".spv")))
		var shader := rd.shader_create_from_spirv(spirv, label)
		var pipeline := rd.compute_pipeline_create(shader)
		_check(shader.is_valid() and pipeline.is_valid(), label + "_pipeline")
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		format.width = 1
		format.height = 1
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		var texture := rd.texture_create(format, RDTextureView.new(), [PackedFloat32Array([0.25]).to_byte_array()])
		var state := RDSamplerState.new()
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		var sampler := rd.sampler_create(state)
		var output := rd.storage_buffer_create(4)
		var input_uniform := RDUniform.new()
		input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		input_uniform.binding = 0
		input_uniform.add_id(sampler)
		input_uniform.add_id(texture)
		var output_uniform := RDUniform.new()
		output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		output_uniform.binding = 1
		output_uniform.add_id(output)
		var uniforms := rd.uniform_set_create([input_uniform, output_uniform], shader, 0)
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands, pipeline)
		rd.compute_list_bind_uniform_set(commands, uniforms, 0)
		rd.compute_list_dispatch(commands, 1, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var values := rd.buffer_get_data(output).to_float32_array()
		_check(values.size() == 1 and is_finite(values[0]) and absf(values[0] - 0.25) < 0.00001, label + "_value", values)
		_check(rd.texture_get_data(texture, 0) == PackedFloat32Array([0.25]).to_byte_array(), label + "_source_unchanged")
		for rid: RID in [uniforms, output, sampler, texture, pipeline, shader]: rd.free_rid(rid)
	rd.free()
	print("SAMPLED_LITERALS COMPLETE passed=%d failed=%d" % [passed, failed])
	quit(0 if passed == 12 and failed == 0 else 1)
