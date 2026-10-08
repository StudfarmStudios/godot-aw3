extends SceneTree

var passed := 0
var failed := 0
var corpus := ""

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--corpus="):
			corpus = argument.trim_prefix("--corpus=")
	if corpus.is_empty():
		push_error("--corpus must name the run_translation.py output directory")
		quit(1)
		return
	RenderingServer.call_on_render_thread(_run)

func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("TINT_GPU PASS ", label)
	else:
		failed += 1
		print("TINT_GPU FAIL ", label)

func _run() -> void:
	var rd := RenderingServer.get_rendering_device()
	for version: String in ["1.0", "1.3", "1.4", "1.5"]:
		for shader_name: String in ["atomic_matrix.comp", "initialized_local_arrays.comp", "initialized_operand_arrays.comp", "nested_logical_copy.comp"]:
			var owned: Array[RID] = []
			var spirv := RDShaderSPIRV.new()
			spirv.set_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE, FileAccess.get_file_as_bytes(corpus.path_join(shader_name + "." + version + ".spv")))
			var shader := rd.shader_create_from_spirv(spirv)
			if not shader.is_valid():
				_check(false, shader_name + " " + version + " shader creation")
				continue
			owned.append(shader)
			var uniforms: Array[RDUniform] = []
			var data := PackedByteArray()
			var expected := PackedByteArray()
			var output_binding := 0
			if shader_name == "atomic_matrix.comp":
				data.resize(96)
				for index in 16:
					data.encode_float(16 + index * 4, float(index))
				expected = data.duplicate()
				expected.encode_u32(0, 4)
				for index in 4:
					expected.encode_float(80 + index * 4, 15.0 + float(index))
			elif shader_name.begins_with("initialized_"):
				data.resize(64)
				expected.resize(64)
				for index in 4:
					for component in 4:
						expected.encode_float((index * 4 + component) * 4, float(1 + index % 3 + 4 + index % 2))
			else:
				var input_data := PackedByteArray()
				input_data.resize(32)
				for index in 8:
					input_data.encode_float(index * 4, float(index + 1))
				var input := rd.uniform_buffer_create(32, input_data)
				owned.append(input)
				var uniform := RDUniform.new()
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				uniform.binding = 0
				uniform.add_id(input)
				uniforms.append(uniform)
				output_binding = 1
				data.resize(16)
				expected = input_data.slice(16)
			var output := rd.storage_buffer_create(data.size(), data)
			owned.append(output)
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding = output_binding
			uniform.add_id(output)
			uniforms.append(uniform)
			var set := rd.uniform_set_create(uniforms, shader, 0)
			owned.append(set)
			var pipeline := rd.compute_pipeline_create(shader)
			owned.append(pipeline)
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, set, 0)
			rd.compute_list_dispatch(list, 1, 1, 1)
			rd.compute_list_end()
			var actual := rd.buffer_get_data(output)
			_check(actual == expected, shader_name + " SPIR-V " + version)
			owned.reverse()
			for rid in owned:
				if rid.is_valid():
					rd.free_rid(rid)
	_run_images(rd)
	print("TINT_GPU COMPLETE passed=%d failed=%d" % [passed, failed])
	call_deferred("quit", 0 if failed == 0 else 1)

func _run_images(rd: RenderingDevice) -> void:
	for version: String in ["1.0", "1.3", "1.4", "1.5"]:
		for signed_value: bool in [false, true]:
			for fetch: bool in [false, true]:
				var owned: Array[RID] = []
				var shader_name := ("integer_fetch_" if fetch else "integer_image_") + ("i" if signed_value else "u") + ".comp"
				var spirv := RDShaderSPIRV.new()
				spirv.set_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE, FileAccess.get_file_as_bytes(corpus.path_join(shader_name + "." + version + ".spv")))
				var shader := rd.shader_create_from_spirv(spirv)
				if not shader.is_valid():
					_check(false, shader_name + " " + version + " creation")
					continue
				owned.append(shader)
				var format := RDTextureFormat.new()
				format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_SINT if signed_value else RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
				format.width = 2 if fetch else 1
				format.height = format.width
				format.mipmaps = 2 if fetch else 1
				format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
				if not fetch:
					format.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
				var texel := PackedByteArray([128, 255, 127, 0])
				var data := PackedByteArray()
				if fetch:
					data.resize(16)
					data.fill(3) # A lost Lod operand must fail the result comparison.
				data.append_array(texel)
				var source := rd.texture_create(format, RDTextureView.new(), [data])
				owned.append(source)
				var destination := RID()
				var sampler := RID()
				if fetch:
					sampler = rd.sampler_create(RDSamplerState.new())
					owned.append(sampler)
				else:
					destination = rd.texture_create(format, RDTextureView.new())
					owned.append(destination)
				var output := rd.storage_buffer_create(16)
				owned.append(output)
				var uniforms: Array[RDUniform] = []
				for index in 3:
					var uniform := RDUniform.new()
					uniform.binding = index
					if index == 2:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
						uniform.add_id(output)
					elif fetch:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE if index == 0 else RenderingDevice.UNIFORM_TYPE_SAMPLER
						uniform.add_id(source if index == 0 else sampler)
					else:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
						uniform.add_id(source if index == 0 else destination)
					uniforms.append(uniform)
				var set := rd.uniform_set_create(uniforms, shader, 0)
				owned.append(set)
				var pipeline := rd.compute_pipeline_create(shader)
				owned.append(pipeline)
				var list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(list, pipeline)
				rd.compute_list_bind_uniform_set(list, set, 0)
				rd.compute_list_dispatch(list, 1, 1, 1)
				rd.compute_list_end()
				var expected := PackedByteArray()
				expected.resize(16)
				for index in 4:
					var value := int(texel[index])
					if signed_value and value >= 128:
						value -= 256
					expected.encode_s32(index * 4, value)
				var okay := rd.buffer_get_data(output) == expected
				if not fetch:
					okay = okay and rd.texture_get_data(destination, 0) == texel
				_check(okay, shader_name + " SPIR-V " + version)
				owned.reverse()
				for rid in owned:
					if rid.is_valid():
						rd.free_rid(rid)
