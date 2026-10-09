extends Node

# Runs the production RenderingDevice/WebGPU driver, not a JS model. The runner
# must also reject engine validation errors, even when our numerical checks pass.
var rd: RenderingDevice
var owned: Array[RID] = []
var expected_results := 0
var completed := 0
var failed := 0
var started := Time.get_ticks_msec()

func _ready() -> void:
	RenderingServer.call_on_render_thread(_run)

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() - started > 90000:
		push_error("DRIVER_TEST timeout: %d/%d callbacks" % [completed, expected_results])
		get_tree().quit(2)

func _result(label: String, success: bool, detail: String = "") -> void:
	completed += 1
	if not success:
		failed += 1
	print("DRIVER_TEST %s %s %s" % ["PASS" if success else "FAIL", label, detail])
	if completed == expected_results:
		RenderingServer.call_on_render_thread(_cleanup)

func _cleanup() -> void:
	for i in range(owned.size() - 1, -1, -1):
		rd.free_rid(owned[i])
	call_deferred("_finish")

func _finish() -> void:
	print("DRIVER_TEST COMPLETE passed=%d failed=%d" % [completed - failed, failed])
	get_tree().quit(0 if failed == 0 else 1)

func _own(id: RID) -> RID:
	owned.append(id)
	return id

func _read(label: String, texture: RID, layer: int, expected: PackedByteArray) -> void:
	expected_results += 1
	var callback := func(actual: PackedByteArray) -> void:
		call_deferred("_result", label, actual == expected,
			"bytes=%d expected=%d" % [actual.size(), expected.size()])
	var error := rd.texture_get_data_async(texture, layer, callback)
	if error != OK:
		call_deferred("_result", label, false, "readback error=%d" % error)

func _format(format: int, width: int, height: int, type: int = RenderingDevice.TEXTURE_TYPE_2D, count: int = 1, mips: int = 1) -> RDTextureFormat:
	var tf := RDTextureFormat.new()
	tf.format = format
	tf.width = width
	tf.height = height
	tf.texture_type = type
	tf.depth = count if type == RenderingDevice.TEXTURE_TYPE_3D else 1
	tf.array_layers = count if type == RenderingDevice.TEXTURE_TYPE_2D_ARRAY else 1
	tf.mipmaps = mips
	tf.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	return tf

func _shader(dimension: String, write_only: bool) -> RID:
	var source := RDShaderSource.new()
	var coords := "ivec2(gl_GlobalInvocationID.xy)" if dimension == "2D" else "ivec3(gl_GlobalInvocationID.xyz)"
	var value := "params.delta + float(gl_GlobalInvocationID.z)" if write_only else "imageLoad(value_image, c).r + params.delta"
	source.source_compute = """#version 450
layout(local_size_x=1, local_size_y=1, local_size_z=1) in;
layout(push_constant, std430) uniform Params { float delta; } params;
layout(r32f, set=0, binding=0) uniform %simage%s value_image;
void main() { %s c = %s; imageStore(value_image, c, vec4(%s)); }
""" % ["writeonly " if write_only else "", dimension, "ivec2" if dimension == "2D" else "ivec3", coords, value]
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
	return _own(rd.shader_create_from_spirv(spirv))

func _write_then_increment(texture: RID, dimension: String, width: int, height: int, depth: int) -> void:
	var writer := _shader(dimension, true)
	var reader := _shader(dimension, false)
	var write_pipeline := _own(rd.compute_pipeline_create(writer))
	var read_pipeline := _own(rd.compute_pipeline_create(reader))
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture)
	# The set's source layout has no read/write shadow. The reader requires an
	# adapted layout and its first snapshot must include the writer's GPU work.
	var uniform_set := _own(rd.uniform_set_create([uniform], writer, 0))
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, write_pipeline)
	rd.compute_list_bind_uniform_set(commands, uniform_set, 0)
	rd.compute_list_set_push_constant(commands, PackedFloat32Array([7.0]).to_byte_array(), 4)
	rd.compute_list_dispatch(commands, width, height, depth)
	rd.compute_list_add_barrier(commands)
	rd.compute_list_bind_compute_pipeline(commands, read_pipeline)
	rd.compute_list_set_push_constant(commands, PackedFloat32Array([1.0]).to_byte_array(), 4)
	rd.compute_list_bind_uniform_set(commands, uniform_set, 0)
	# Rebinding must not perform additional snapshots.
	rd.compute_list_bind_uniform_set(commands, uniform_set, 0)
	rd.compute_list_dispatch(commands, width, height, depth)
	rd.compute_list_add_barrier(commands)
	# No intervening bind: refresh belongs to dispatch, not set binding.
	rd.compute_list_dispatch(commands, width, height, depth)
	rd.compute_list_end()

func _floats(count: int, value: float) -> PackedByteArray:
	var data := PackedFloat32Array()
	data.resize(count)
	data.fill(value)
	return data.to_byte_array()

func _test_resolve(samples: int, storage: bool, sliced: bool = false) -> void:
	var label := "MSAA %dx storage=%s slice=%s" % [1 << samples, storage, sliced]
	var tf := _format(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, 7, 3)
	tf.samples = samples
	tf.usage_bits = (RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	var source := _own(rd.texture_create(tf, RDTextureView.new()))
	expected_results += 1
	call_deferred("_result", label + " effective samples", rd.texture_get_format(source).samples == RenderingDevice.TEXTURE_SAMPLES_4)
	var framebuffer := _own(rd.framebuffer_create([source]))
	rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_ALL, [Color(0.125, 0.625, 0.0, 1.0)])
	rd.draw_list_end()
	var df := _format(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, 14 if sliced else 7, 6 if sliced else 3,
		RenderingDevice.TEXTURE_TYPE_2D_ARRAY if sliced else RenderingDevice.TEXTURE_TYPE_2D, 2 if sliced else 1, 2 if sliced else 1)
	df.usage_bits |= RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
	if not storage:
		df.usage_bits &= ~RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var dest := _own(rd.texture_create(df, RDTextureView.new()))
	var target := _own(rd.texture_create_shared_from_slice(RDTextureView.new(), dest, 1, 1, 1)) if sliced else dest
	var error := rd.texture_resolve_multisample(source, target)
	if error != OK:
		push_error("%s resolve failed: %d" % [label, error])
	var expected := PackedByteArray()
	expected.resize((84 + 21 if sliced else 21) * 4)
	for pixel in 21:
		# 0.125 and 0.625 in half precision, including promoted RG32F readback.
		expected.encode_u32(((84 if sliced else 0) + pixel) * 4, 0x39003000)
	_read(label + " resolve", dest, 1 if sliced else 0, expected)
	if sliced:
		var zeros := PackedByteArray()
		zeros.resize(105 * 4)
		_read(label + " untouched layer", dest, 0, zeros)

func _run() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		expected_results = 1
		call_deferred("_result", "RenderingDevice available", false, "Forward+ WebGPU required")
		return
	print("DRIVER_TEST engine=%s adapter=%s vendor=%s args=%s" % [Engine.get_version_info().hash,
		rd.get_device_name(), rd.get_device_vendor_name(), OS.get_cmdline_user_args()])
	preload("partial_clears.gd").new().run(self)
	preload("storage_access.gd").new().run(self)
	for samples in [RenderingDevice.TEXTURE_SAMPLES_2, RenderingDevice.TEXTURE_SAMPLES_4, RenderingDevice.TEXTURE_SAMPLES_8]:
		for storage in [false, true]:
			_test_resolve(samples, storage)
	for storage in [false, true]:
		_test_resolve(RenderingDevice.TEXTURE_SAMPLES_4, storage, true)
	for entry in [
		["rgb10a2-unorm", RenderingDevice.DATA_FORMAT_A2B10G10R10_UNORM_PACK32, 0xc00003ff, 4],
		["rgb10a2-uint", RenderingDevice.DATA_FORMAT_A2B10G10R10_UINT_PACK32, 0xffffffff, 4],
		["rg11b10-float", RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32, 0x781e03c0, 4],
		["r8-uint", RenderingDevice.DATA_FORMAT_R8_UINT, 253, 1],
		["rg8-sint", RenderingDevice.DATA_FORMAT_R8G8_SINT, 0x7f80, 2],
		["r16-uint", RenderingDevice.DATA_FORMAT_R16_UINT, 65530, 2],
		["r16-sint", RenderingDevice.DATA_FORMAT_R16_SINT, 0x8000, 2],
		["rg16-half", RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, 0xbc003c00, 4],
	]:
		var tf := _format(entry[1], 3, 2)
		var data := PackedByteArray()
		data.resize(6 * entry[3])
		for pixel in 6:
			for byte in entry[3]:
				data[pixel * entry[3] + byte] = (entry[2] >> (8 * byte)) & 255
		var texture := _own(rd.texture_create(tf, RDTextureView.new(), [data]))
		_read(entry[0] + " upload/readback", texture, 0, data)
		var shared := _own(rd.texture_create_shared(RDTextureView.new(), texture))
		_read(entry[0] + " shared view", shared, 0, data)
	for shape in [["2D", RenderingDevice.TEXTURE_TYPE_2D, 1],
		["2DArray", RenderingDevice.TEXTURE_TYPE_2D_ARRAY, 3],
		["3D", RenderingDevice.TEXTURE_TYPE_3D, 3]]:
		var tf := _format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, 4, 3, shape[1], shape[2])
		var texture := _own(rd.texture_create(tf, RDTextureView.new()))
		_write_then_increment(texture, shape[0], 4, 3, shape[2])
		for layer in tf.array_layers:
			var expected_volume := PackedByteArray()
			for z in tf.depth:
				expected_volume.append_array(_floats(12, 9.0 + layer + z))
			_read("GPU shadow %s layer %d" % [shape[0], layer], texture, layer, expected_volume)
	var parent_format := _format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, 8, 8,
		RenderingDevice.TEXTURE_TYPE_2D_ARRAY, 3, 4)
	var parent := _own(rd.texture_create(parent_format, RDTextureView.new()))
	var slice := _own(rd.texture_create_shared_from_slice(RDTextureView.new(), parent, 1, 1, 1))
	_write_then_increment(slice, "2D", 4, 4, 1)
	var expected := _floats(64 + 16 + 4 + 1, 0.0)
	for pixel in 16:
		expected.encode_float((64 + pixel) * 4, 9.0)
	_read("GPU shadow mip 1 layer 1", parent, 1, expected)
	_read("GPU shadow untouched layer", parent, 2, _floats(85, 0.0))

	# Every BC3 mip occupies whole 4x4 blocks, including logical 2x2 and 1x1
	# tails. Distinct layer data catches both extent and array-stride mistakes.
	var compressed_format := _format(RenderingDevice.DATA_FORMAT_BC3_UNORM_BLOCK, 8, 8,
		RenderingDevice.TEXTURE_TYPE_2D_ARRAY, 2, 4)
	compressed_format.usage_bits &= ~RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var layer_data: Array[PackedByteArray] = []
	for layer in 2:
		var bytes := PackedByteArray()
		bytes.resize(112)
		for index in bytes.size():
			bytes[index] = (index * 17 + layer * 71) & 255
		layer_data.append(bytes)
	var compressed_source := _own(rd.texture_create(compressed_format, RDTextureView.new(), layer_data))
	var compressed_dest := _own(rd.texture_create(compressed_format, RDTextureView.new()))
	for layer in 2:
		for mip in 4:
			var side := maxi(1, 8 >> mip)
			rd.texture_copy(compressed_source, compressed_dest, Vector3.ZERO, Vector3.ZERO,
				Vector3(side, side, 1), mip, mip, layer, layer)
		_read("compressed mip tail layer %d" % layer, compressed_dest, layer, layer_data[layer])
