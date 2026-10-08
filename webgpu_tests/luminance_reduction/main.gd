extends SceneTree

# Compile the production shader, then compare GPU reductions with direct CPU
# averages. Dimensions smaller than a workgroup expose one-axis-only OOB reads.
const CASES := [Vector2i(1, 1), Vector2i(3, 2), Vector2i(5, 3), Vector2i(7, 7), Vector2i(8, 8), Vector2i(13, 9)]
var rd: RenderingDevice
var owned: Array[RID] = []
var shader_path := ""
var legacy_bounds := false
var passed := 0
var failed := 0

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--luminance-shader="):
			shader_path = argument.trim_prefix("--luminance-shader=")
		elif argument == "--legacy-bounds":
			legacy_bounds = true
	call_deferred("_run")

func _own(rid: RID) -> RID:
	if rid.is_valid():
		owned.append(rid)
	return rid

func _uniform(type: int, resources: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = 0
	for resource in resources:
		uniform.add_id(resource)
	return uniform

func _texture(size: Vector2i, bytes: PackedByteArray) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _own(rd.texture_create(format, RDTextureView.new(), [bytes] if not bytes.is_empty() else []))

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Local RenderingDevice unavailable")
		quit(2)
		return
	var production := FileAccess.get_file_as_string(shader_path)
	if not production.contains("if (all(lessThan(pos, params.source_size)))"):
		push_error("Expected corrected bounds predicate in production luminance shader")
		quit(2)
		return
	if legacy_bounds:
		production = production.replace("if (all(lessThan(pos, params.source_size)))", "if (any(lessThan(pos, params.source_size)))")
	var sampler := _own(rd.sampler_create(RDSamplerState.new()))
	for read_texture in [false, true]:
		var source := RDShaderSource.new()
		source.source_compute = production.replace("#[compute]", "").replace("#VERSION_DEFINES", "#define WRITE_LUMINANCE\n" + ("#define READ_TEXTURE\n" if read_texture else ""))
		var spirv := rd.shader_compile_spirv_from_source(source, false)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			quit(2)
			return
		var shader := _own(rd.shader_create_from_spirv(spirv))
		var pipeline := _own(rd.compute_pipeline_create(shader))
		for size: Vector2i in CASES:
			var input := PackedByteArray()
			input.resize(size.x * size.y * 4)
			# Exactly representable, nonuniform positive values catch edge duplication.
			for index in size.x * size.y:
				input.encode_float(index * 4, 0.125 + float(index % 13) / 32.0)
			var input_texture := _texture(size, input)
			var output_size := Vector2i((size.x + 7) / 8, (size.y + 7) / 8)
			var output_texture := _texture(output_size, PackedByteArray())
			var previous_texture := _texture(Vector2i.ONE, PackedFloat32Array([1.0]).to_byte_array())
			var source_uniform := _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, input_texture]) if read_texture else _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, [input_texture])
			var sets: Array[RID] = [
				_own(rd.uniform_set_create([source_uniform], shader, 0)),
				_own(rd.uniform_set_create([_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, [output_texture])], shader, 1)),
				_own(rd.uniform_set_create([_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, previous_texture])], shader, 2))]
			for adjust in [1.0, 1.0 / 6.0]:
				var constants := PackedByteArray()
				constants.resize(32)
				constants.encode_s32(0, size.x)
				constants.encode_s32(4, size.y)
				constants.encode_float(8, 64.0)
				constants.encode_float(12, 0.0)
				constants.encode_float(16, adjust)
				var commands := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(commands, pipeline)
				for set_index in 3:
					rd.compute_list_bind_uniform_set(commands, sets[set_index], set_index)
				rd.compute_list_set_push_constant(commands, constants, constants.size())
				rd.compute_list_dispatch(commands, output_size.x, output_size.y, 1)
				rd.compute_list_end()
				rd.submit()
				rd.sync()
				var actual := rd.texture_get_data(output_texture, 0)
				var valid := actual.size() == output_size.x * output_size.y * 4
				var max_error := 0.0
				for tile_y in output_size.y:
					for tile_x in output_size.x:
						var total := 0.0
						var count := 0
						for y in range(tile_y * 8, mini(size.y, (tile_y + 1) * 8)):
							for x in range(tile_x * 8, mini(size.x, (tile_x + 1) * 8)):
								total += input.decode_float((y * size.x + x) * 4)
								count += 1
						var expected: float = 1.0 + (total / count - 1.0) * adjust
						var value := actual.decode_float((tile_y * output_size.x + tile_x) * 4) if valid else NAN
						valid = valid and is_finite(value) and absf(value - expected) < 0.00001
						if is_finite(value):
							max_error = maxf(max_error, absf(value - expected))
				passed += int(valid)
				failed += int(not valid)
				print("LUMINANCE_REDUCTION %s sampled=%s size=%dx%d adjust=%.6f max_error=%.9f" % ["PASS" if valid else "FAIL", read_texture, size.x, size.y, adjust, max_error])
	for index in range(owned.size() - 1, -1, -1):
		rd.free_rid(owned[index])
	rd.free()
	print("LUMINANCE_REDUCTION COMPLETE passed=%d failed=%d legacy=%s" % [passed, failed, legacy_bounds])
	quit(0 if failed == 0 and passed == 24 else 1)
