extends SceneTree

var directory := ""
var owned: Array[RID] = []
var rd: RenderingDevice

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture-dir="):
			directory = argument.trim_prefix("--fixture-dir=")
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
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(directory.path_join("depth.comp"))
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(2)
		return
	var shader := own(rd.shader_create_from_spirv(spirv))
	var pipeline := own(rd.compute_pipeline_create(shader))
	var format := RDTextureFormat.new()
	format.width = 4
	format.height = 4
	format.format = RenderingDevice.DATA_FORMAT_D32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var depth := own(rd.texture_create(format, RDTextureView.new()))
	var framebuffer := own(rd.framebuffer_create([depth]))
	var output := own(rd.storage_buffer_create(4))
	var sampler := own(rd.sampler_create(RDSamplerState.new()))
	var bindings := own(rd.uniform_set_create([
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, output),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 6, sampler),
		uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 12, depth),
	], shader, 0))
	var failed := 0
	for expected in [0.75, 0.25]:
		rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_DEPTH, [], expected)
		rd.draw_list_end()
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands, pipeline)
		rd.compute_list_bind_uniform_set(commands, bindings, 0)
		rd.compute_list_dispatch(commands, 1, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var actual := rd.buffer_get_data(output).decode_float(0)
		if absf(actual - expected) > 0.000001: failed += 1
		print("SDFGI_DEPTH expected=%f actual=%f" % [expected, actual])
	for index in range(owned.size() - 1, -1, -1): rd.free_rid(owned[index])
	rd.free()
	print("SDFGI_DEPTH COMPLETE checks=2 failed=%d" % failed)
	quit(0 if failed == 0 else 1)
