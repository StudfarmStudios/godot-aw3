extends SceneTree

const SIZE := Vector2i(13, 7)
var rd: RenderingDevice
var owned: Array[RID] = []
var output_directory := ""
var passed := 0
var failed := 0

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--specialization-output="):
			output_directory = argument.trim_prefix("--specialization-output=")
	call_deferred("_run")

func _own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	return rid

func _uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform

func _texture(format: int, data: PackedByteArray, dimension: String, layers: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.format = format
	tf.width = SIZE.x
	tf.height = SIZE.y
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D if dimension == "3D" else (RenderingDevice.TEXTURE_TYPE_2D_ARRAY if dimension == "2DArray" else RenderingDevice.TEXTURE_TYPE_2D)
	tf.depth = layers if dimension == "3D" else 1
	tf.array_layers = layers if dimension == "2DArray" else 1
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var planes: Array[PackedByteArray] = [data]
	if dimension == "2DArray":
		planes.clear()
		for layer in layers:
			planes.append(data.slice(layer * data.size() / layers, (layer + 1) * data.size() / layers))
	return _own(rd.texture_create(tf, RDTextureView.new(), planes))

func _read(texture: RID, dimension: String, layers: int) -> PackedByteArray:
	var data := PackedByteArray()
	for layer in (layers if dimension == "2DArray" else 1):
		data.append_array(rd.texture_get_data(texture, layer))
	return data

func _constants(count: int, active: bool) -> Array[RDPipelineSpecializationConstant]:
	var a := RDPipelineSpecializationConstant.new()
	a.constant_id = 0
	a.value = count
	var b := RDPipelineSpecializationConstant.new()
	b.constant_id = 1
	b.value = active
	return [a, b]

func _check(label: String, data: PackedByteArray, expected: PackedFloat32Array, components: int, integer: bool) -> void:
	var valid := data.size() == expected.size() * components * 4
	var maximum_error := 0.0
	if valid:
		for index in expected.size():
			for component in components:
				var offset := (index * components + component) * 4
				var actual: float = data.decode_u32(offset) if integer else data.decode_float(offset)
				valid = valid and is_finite(actual) and absf(actual - expected[index]) < 0.00001
				maximum_error = maxf(maximum_error, absf(actual - expected[index]))
	passed += int(valid)
	failed += int(not valid)
	print("SHADER_SPECIALIZATION %s %s bytes=%d max_error=%f" % ["PASS" if valid else "FAIL", label, data.size(), maximum_error])

func _case(format: Array, access: String, typed: bool, pruned: bool, dimension: String = "2D", layers: int = 1) -> void:
	var label := "%s_%s_%s_%s" % [format[0], access, "typed" if typed else "override", "pruned" if pruned else "active"]
	label += "_" + dimension
	print("SHADER_SPECIALIZATION BEGIN ", label)
	var integer: bool = format[3]
	var qualifier := "readonly " if access == "read" else ("writeonly " if access == "write" else "")
	var store_value := "uvec4(uint(value))" if integer else "vec4(value)"
	var operation := "float value = marker;" if access == "write" else "float value = float(imageLoad(source_image, c).r) + marker;"
	if access != "read": operation += "imageStore(source_image, c, %s);" % store_value
	var proof := "float proof[COUNT]; proof[COUNT - 1] = float(COUNT); float marker = proof[COUNT - 1];" if typed else "float marker = float(COUNT);"
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(constant_id=0) const int COUNT = 1;
layout(constant_id=1) const bool ACTIVE = %s;
layout(%s,set=0,binding=0) uniform %s%simage%s source_image;
layout(r32f,set=0,binding=1) uniform writeonly image%s output_image;
void main() {
  %s c = %s;
  %s
  if (ACTIVE) { %s imageStore(output_image, c, vec4(value)); }
  else { imageStore(output_image, c, vec4(marker)); }
}
""" % ["false" if pruned else "true", format[0], qualifier, "u" if integer else "", dimension, dimension, "ivec2" if dimension == "2D" else "ivec3", "ivec2(gl_GlobalInvocationID.xy)" if dimension == "2D" else "ivec3(gl_GlobalInvocationID.xyz)", proof, operation]
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		return
	if not output_directory.is_empty():
		var file := FileAccess.open(output_directory.path_join(label + ".spv"), FileAccess.WRITE)
		file.store_buffer(spirv.bytecode_compute)
		file = FileAccess.open(output_directory.path_join(label + ".comp"), FileAccess.WRITE)
		file.store_string(source.source_compute)
	var shader := _own(rd.shader_create_from_spirv(spirv, label))
	var initial := PackedByteArray()
	initial.resize(SIZE.x * SIZE.y * layers * format[2] * 4)
	var expected := PackedFloat32Array()
	expected.resize(SIZE.x * SIZE.y * layers)
	for index in expected.size():
		expected[index] = 7.0 + float(index % 11) if integer else 0.125 + float(index % 11) / 16.0
		for component in int(format[2]):
			var offset: int = (index * format[2] + component) * 4
			if integer: initial.encode_u32(offset, int(expected[index]))
			else: initial.encode_float(offset, expected[index])
	var input_texture := _texture(format[1], initial, dimension, layers)
	var zeros := PackedByteArray()
	zeros.resize(expected.size() * 4)
	var output_texture := _texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, zeros, dimension, layers)
	var uniforms := _own(rd.uniform_set_create([_uniform(0, input_texture), _uniform(1, output_texture)], shader, 0))
	var base := _own(rd.compute_pipeline_create(shader))
	var active := _own(rd.compute_pipeline_create(shader, _constants(3, true)))
	var inactive := _own(rd.compute_pipeline_create(shader, _constants(2, false)))
	for phase in 4:
		var count := 1 if phase == 0 else (2 if phase == 3 else 3)
		var enabled := not pruned if phase == 0 else phase != 3
		var pipeline := base if phase == 0 else (inactive if phase == 3 else active)
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands, pipeline)
		rd.compute_list_bind_uniform_set(commands, uniforms, 0)
		rd.compute_list_dispatch(commands, SIZE.x, SIZE.y, layers)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var output_expected := PackedFloat32Array()
		output_expected.resize(expected.size())
		for index in expected.size():
			output_expected[index] = count
			if enabled:
				var value: float = count if access == "write" else expected[index] + count
				output_expected[index] = value
				if access != "read": expected[index] = value
		_check("%s_phase%d_source" % [label, phase], _read(input_texture, dimension, layers), expected, format[2], integer)
		_check("%s_phase%d_output" % [label, phase], _read(output_texture, dimension, layers), output_expected, 1, false)
	for index in range(owned.size() - 1, -1, -1): rd.free_rid(owned[index])
	owned.clear()

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Local RenderingDevice unavailable")
		quit(2)
		return
	for format: Array in [["r32f", RenderingDevice.DATA_FORMAT_R32_SFLOAT, 1, false], ["rg32f", RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, 2, false], ["r32ui", RenderingDevice.DATA_FORMAT_R32_UINT, 1, true]]:
		for access: String in ["read", "read_write", "write"]:
			for typed: bool in [false, true]:
				for pruned: bool in [false, true]:
					_case(format, access, typed, pruned)
	for dimension: String in ["3D", "2DArray"]:
		_case(["rg32f", RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, 2, false], "read_write", true, true, dimension, 3)
		_case(["r32ui", RenderingDevice.DATA_FORMAT_R32_UINT, 1, true], "read", true, true, dimension, 3)
	rd.free()
	print("SHADER_SPECIALIZATION COMPLETE passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 and passed == 320 else 1)
