extends SceneTree

const INDEPENDENT_LISTS = 128
const ACTIVE_WORDS = 64
const CANARY_WORDS = 4
const WORDS_PER_LIST = ACTIVE_WORDS + CANARY_WORDS
const CANARY = 0xA5A5A5A5
const COPY_CANARY = 0xC3C3C3C3
const TEXTURE_WIDTH = 8
const TEXTURE_HEIGHT = 8

const INDEPENDENT_SHADER_A = """
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict writeonly buffer OutputBuffer {
	uint values[];
} output_buffer;
layout(set = 0, binding = 1, std140) uniform Parameters {
	uvec4 value;
} parameters;
layout(push_constant, std430) uniform PushConstant {
	uvec4 value;
} push_constant;
void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index < push_constant.value.z) {
		output_buffer.values[index] = parameters.value.x + index * parameters.value.y
				+ push_constant.value.x * 17u + push_constant.value.y;
	}
}
"""

const INDEPENDENT_SHADER_B = """
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict writeonly buffer OutputBuffer {
	uint values[];
} output_buffer;
layout(set = 0, binding = 1, std140) uniform Parameters {
	uvec4 value;
} parameters;
layout(push_constant, std430) uniform PushConstant {
	uvec4 value;
} push_constant;
void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index < push_constant.value.z) {
		output_buffer.values[index] = (parameters.value.x ^ (index * parameters.value.y
				+ push_constant.value.x)) + push_constant.value.y;
	}
}
"""

const MATH_SHADER = """
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict buffer DataBuffer {
	uint values[];
} data_buffer;
layout(push_constant, std430) uniform PushConstant {
	uvec4 value; // operation, operand, count, word offset
} push_constant;
void main() {
	uint invocation = gl_GlobalInvocationID.x;
	if (invocation >= push_constant.value.z) {
		return;
	}
	uint index = invocation + push_constant.value.w;
	uint operation = push_constant.value.x;
	if (operation == 0u) {
		data_buffer.values[index] += push_constant.value.y;
	} else if (operation == 1u) {
		data_buffer.values[index] *= push_constant.value.y;
	} else {
		data_buffer.values[index] ^= push_constant.value.y;
	}
}
"""

const TEXTURE_WRITE_SHADER = """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(r32ui, set = 0, binding = 0) uniform restrict writeonly uimage2D output_image;
layout(push_constant, std430) uniform PushConstant {
	uvec4 value; // seed, width, height, unused
} push_constant;
void main() {
	uvec2 position = gl_GlobalInvocationID.xy;
	if (position.x < push_constant.value.y && position.y < push_constant.value.z) {
		uint value = push_constant.value.x + position.x * 17u + position.y * 257u;
		imageStore(output_image, ivec2(position), uvec4(value, 0u, 0u, 0u));
	}
}
"""

const TEXTURE_READ_SHADER = """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(r32ui, set = 0, binding = 0) uniform restrict readonly uimage2D input_image;
layout(set = 0, binding = 1, std430) restrict writeonly buffer OutputBuffer {
	uint values[];
} output_buffer;
layout(push_constant, std430) uniform PushConstant {
	uvec4 value; // xor mask, width, height, unused
} push_constant;
void main() {
	uvec2 position = gl_GlobalInvocationID.xy;
	if (position.x < push_constant.value.y && position.y < push_constant.value.z) {
		uint index = position.y * push_constant.value.y + position.x;
		output_buffer.values[index] = imageLoad(input_image, ivec2(position)).x ^ push_constant.value.x;
	}
}
"""

var failures = 0
var shader_rids: Array[RID] = []
var pipeline_rids: Array[RID] = []
var uniform_set_rids: Array[RID] = []
var buffer_rids: Array[RID] = []
var texture_rids: Array[RID] = []
var readback_data: Dictionary = {}


func _initialize():
	call_deferred("run")


func make_u32_bytes(values: Array) -> PackedByteArray:
	var bytes = PackedByteArray()
	bytes.resize(values.size() * 4)
	for index in range(values.size()):
		bytes.encode_u32(index * 4, int(values[index]) & 0xFFFFFFFF)
	return bytes


func repeated_words(value: int, count: int) -> PackedByteArray:
	var bytes = PackedByteArray()
	bytes.resize(count * 4)
	for index in range(count):
		bytes.encode_u32(index * 4, value & 0xFFFFFFFF)
	return bytes


func make_push(a: int, b: int, c: int, d: int = 0) -> PackedByteArray:
	return make_u32_bytes([a, b, c, d])


func compile_compute(rd: RenderingDevice, source_text: String, label: String) -> Dictionary:
	var source = RDShaderSource.new()
	source.source_compute = source_text
	var spirv = rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("%s shader compile failed:\n%s" % [label, spirv.compile_error_compute])
		return {}
	var shader = rd.shader_create_from_spirv(spirv, label)
	if not shader.is_valid():
		push_error("%s shader creation failed" % label)
		return {}
	var pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid() or not rd.compute_pipeline_is_valid(pipeline):
		push_error("%s pipeline creation failed" % label)
		rd.free_rid(shader)
		return {}
	shader_rids.append(shader)
	pipeline_rids.append(pipeline)
	return {"shader": shader, "pipeline": pipeline}


func storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func uniform_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func keep_buffer(buffer: RID) -> RID:
	buffer_rids.append(buffer)
	return buffer


func keep_set(uniform_set: RID) -> RID:
	uniform_set_rids.append(uniform_set)
	return uniform_set


func report_failure(section: String, detail: String):
	failures += 1
	print("COMPUTE_ENCODER_PROBE_FAIL section=%s %s" % [section, detail])


func capture_readback(bytes: PackedByteArray, key: String):
	# RenderingDevice reuses its callback array for later requests. Keep each
	# result independent so all sections can be verified after sync() returns.
	readback_data[key] = bytes.duplicate()


func request_buffer_readback(rd: RenderingDevice, key: String, buffer: RID):
	var err = rd.buffer_get_data_async(buffer, Callable(self, "capture_readback").bind(key))
	if err != OK:
		report_failure("readback", "buffer=%s request_error=%d" % [key, err])


func request_texture_readback(rd: RenderingDevice, key: String, texture: RID):
	var err = rd.texture_get_data_async(texture, 0, Callable(self, "capture_readback").bind(key))
	if err != OK:
		report_failure("readback", "texture=%s request_error=%d" % [key, err])


func get_readback(key: String) -> PackedByteArray:
	if not readback_data.has(key):
		report_failure("readback", "callback_missing=%s" % key)
		return PackedByteArray()
	return readback_data[key]


func verify_word(section: String, bytes: PackedByteArray, word_index: int, expected: int):
	var byte_offset = word_index * 4
	if byte_offset + 4 > bytes.size():
		report_failure(section, "word=%d missing readback_bytes=%d" % [word_index, bytes.size()])
		return
	var actual = bytes.decode_u32(byte_offset)
	var normalized_expected = expected & 0xFFFFFFFF
	if actual != normalized_expected:
		report_failure(section, "word=%d expected=0x%08x actual=0x%08x" % [word_index, normalized_expected, actual])


func record_independent_lists(rd: RenderingDevice, variants: Array) -> Dictionary:
	var outputs: Array[RID] = []
	for list_index in range(INDEPENDENT_LISTS):
		var variant_index = list_index & 1
		var variant: Dictionary = variants[variant_index]
		var output = keep_buffer(rd.storage_buffer_create(WORDS_PER_LIST * 4, repeated_words(CANARY, WORDS_PER_LIST)))
		var base = 1000 + list_index * 31
		var stride = 3 + (list_index % 11)
		var parameter_buffer = keep_buffer(rd.uniform_buffer_create(16, make_u32_bytes([base, stride, list_index ^ 0x1234, 0])))
		var uniform_set = keep_set(rd.uniform_set_create([
			storage_uniform(0, output),
			uniform_buffer_uniform(1, parameter_buffer),
		], variant.shader, 0))
		outputs.append(output)
		var list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, variant.pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, make_push(list_index, 700 + list_index, ACTIVE_WORDS), 16)
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()

	# One readback buffer keeps verification cheap. These independent copies also
	# put a real blit level after the large independent compute level.
	var readback = keep_buffer(rd.storage_buffer_create(INDEPENDENT_LISTS * WORDS_PER_LIST * 4,
			repeated_words(0xDEADBEEF, INDEPENDENT_LISTS * WORDS_PER_LIST)))
	for list_index in range(INDEPENDENT_LISTS):
		var err = rd.buffer_copy(outputs[list_index], readback, 0, list_index * WORDS_PER_LIST * 4, WORDS_PER_LIST * 4)
		if err != OK:
			report_failure("independent", "buffer_copy list=%d error=%d" % [list_index, err])
	return {"buffer": readback}


func record_dependent_chain(rd: RenderingDevice, math_variant: Dictionary) -> Dictionary:
	var initial: Array = []
	for index in range(ACTIVE_WORDS):
		initial.append(index)
	for unused in range(CANARY_WORDS):
		initial.append(CANARY)
	var buffer = keep_buffer(rd.storage_buffer_create(initial.size() * 4, make_u32_bytes(initial)))
	var uniform_set = keep_set(rd.uniform_set_create([storage_uniform(0, buffer)], math_variant.shader, 0))

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, math_variant.pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, make_push(0, 5, ACTIVE_WORDS), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_set_push_constant(list, make_push(1, 3, ACTIVE_WORDS), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_set_push_constant(list, make_push(2, 0x55AA, ACTIVE_WORDS), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()

	# A separate logical list reads and writes the same tracked buffer. It must be
	# ordered after all three barrier-separated commands above.
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, math_variant.pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, make_push(0, 7, ACTIVE_WORDS), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	return {"buffer": buffer}


func record_copy_boundary(rd: RenderingDevice, math_variant: Dictionary) -> Dictionary:
	const PREFIX = 4
	var source_words: Array = []
	for unused in range(PREFIX):
		source_words.append(COPY_CANARY)
	for index in range(ACTIVE_WORDS):
		source_words.append(index)
	for unused in range(CANARY_WORDS):
		source_words.append(COPY_CANARY)
	var source = keep_buffer(rd.storage_buffer_create(source_words.size() * 4, make_u32_bytes(source_words)))
	var destination = keep_buffer(rd.storage_buffer_create(source_words.size() * 4,
			repeated_words(COPY_CANARY, source_words.size())))
	var source_set = keep_set(rd.uniform_set_create([storage_uniform(0, source)], math_variant.shader, 0))
	var destination_set = keep_set(rd.uniform_set_create([storage_uniform(0, destination)], math_variant.shader, 0))

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, math_variant.pipeline)
	rd.compute_list_bind_uniform_set(list, source_set, 0)
	rd.compute_list_set_push_constant(list, make_push(0, 100, ACTIVE_WORDS, PREFIX), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	var err = rd.buffer_copy(source, destination, PREFIX * 4, PREFIX * 4, ACTIVE_WORDS * 4)
	if err != OK:
		report_failure("copy", "buffer_copy error=%d" % err)
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, math_variant.pipeline)
	rd.compute_list_bind_uniform_set(list, destination_set, 0)
	rd.compute_list_set_push_constant(list, make_push(1, 7, ACTIVE_WORDS, PREFIX), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	return {"source": source, "destination": destination, "prefix": PREFIX}


func record_texture_chain(rd: RenderingDevice, writer: Dictionary, reader: Dictionary) -> Dictionary:
	var format = RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R32_UINT
	format.width = TEXTURE_WIDTH
	format.height = TEXTURE_HEIGHT
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var texture_bytes = repeated_words(0, TEXTURE_WIDTH * TEXTURE_HEIGHT)
	var texture = rd.texture_create(format, RDTextureView.new(), [texture_bytes])
	texture_rids.append(texture)
	var output = keep_buffer(rd.storage_buffer_create((TEXTURE_WIDTH * TEXTURE_HEIGHT + CANARY_WORDS) * 4,
			repeated_words(CANARY, TEXTURE_WIDTH * TEXTURE_HEIGHT + CANARY_WORDS)))
	var write_set = keep_set(rd.uniform_set_create([image_uniform(0, texture)], writer.shader, 0))
	var read_set = keep_set(rd.uniform_set_create([
		image_uniform(0, texture),
		storage_uniform(1, output),
	], reader.shader, 0))
	var seed = 0x10203040
	var xor_mask = 0x00FF00FF

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, writer.pipeline)
	rd.compute_list_bind_uniform_set(list, write_set, 0)
	rd.compute_list_set_push_constant(list, make_push(seed, TEXTURE_WIDTH, TEXTURE_HEIGHT), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()

	# The second list reads the image written by the first, forcing a tracked
	# image dependency and a new render-graph level.
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, reader.pipeline)
	rd.compute_list_bind_uniform_set(list, read_set, 0)
	rd.compute_list_set_push_constant(list, make_push(xor_mask, TEXTURE_WIDTH, TEXTURE_HEIGHT), 16)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	return {"texture": texture, "output": output, "seed": seed, "xor_mask": xor_mask}


func verify_independent(bytes: PackedByteArray):
	for list_index in range(INDEPENDENT_LISTS):
		var base = 1000 + list_index * 31
		var stride = 3 + (list_index % 11)
		var chunk = list_index * WORDS_PER_LIST
		for index in range(ACTIVE_WORDS):
			var expected: int
			if (list_index & 1) == 0:
				expected = base + index * stride + list_index * 17 + 700 + list_index
			else:
				expected = (base ^ (index * stride + list_index)) + 700 + list_index
			verify_word("independent", bytes, chunk + index, expected)
		for canary_index in range(CANARY_WORDS):
			verify_word("independent_canary", bytes, chunk + ACTIVE_WORDS + canary_index, CANARY)


func verify_dependent(bytes: PackedByteArray):
	for index in range(ACTIVE_WORDS):
		verify_word("dependent", bytes, index, (((index + 5) * 3) ^ 0x55AA) + 7)
	for canary_index in range(CANARY_WORDS):
		verify_word("dependent_canary", bytes, ACTIVE_WORDS + canary_index, CANARY)


func verify_copy(record: Dictionary, source: PackedByteArray, destination: PackedByteArray):
	var prefix: int = record.prefix
	for index in range(prefix):
		verify_word("copy_source_prefix", source, index, COPY_CANARY)
		verify_word("copy_destination_prefix", destination, index, COPY_CANARY)
	for index in range(ACTIVE_WORDS):
		verify_word("copy_source", source, prefix + index, index + 100)
		verify_word("copy_destination", destination, prefix + index, (index + 100) * 7)
	for index in range(CANARY_WORDS):
		verify_word("copy_source_suffix", source, prefix + ACTIVE_WORDS + index, COPY_CANARY)
		verify_word("copy_destination_suffix", destination, prefix + ACTIVE_WORDS + index, COPY_CANARY)


func verify_texture(record: Dictionary, texture_bytes: PackedByteArray, output_bytes: PackedByteArray):
	for y in range(TEXTURE_HEIGHT):
		for x in range(TEXTURE_WIDTH):
			var index = y * TEXTURE_WIDTH + x
			var expected = int(record.seed) + x * 17 + y * 257
			verify_word("texture_readback", texture_bytes, index, expected)
			verify_word("texture_shader_read", output_bytes, index, expected ^ int(record.xor_mask))
	for index in range(CANARY_WORDS):
		verify_word("texture_output_canary", output_bytes, TEXTURE_WIDTH * TEXTURE_HEIGHT + index, CANARY)


func cleanup(rd: RenderingDevice):
	for uniform_set in uniform_set_rids:
		rd.free_rid(uniform_set)
	for pipeline in pipeline_rids:
		rd.free_rid(pipeline)
	for texture in texture_rids:
		rd.free_rid(texture)
	for buffer in buffer_rids:
		rd.free_rid(buffer)
	for shader in shader_rids:
		rd.free_rid(shader)
	rd.free()


func run():
	var rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("This probe requires a renderer with local RenderingDevice support.")
		quit(2)
		return
	print("COMPUTE_ENCODER_PROBE_DEVICE name=%s driver=%s" % [
		rd.get_device_name(),
		RenderingServer.get_current_rendering_driver_name(),
	])

	var independent_a = compile_compute(rd, INDEPENDENT_SHADER_A, "probe_independent_a")
	var independent_b = compile_compute(rd, INDEPENDENT_SHADER_B, "probe_independent_b")
	var math_variant = compile_compute(rd, MATH_SHADER, "probe_math")
	var texture_writer = compile_compute(rd, TEXTURE_WRITE_SHADER, "probe_texture_write")
	var texture_reader = compile_compute(rd, TEXTURE_READ_SHADER, "probe_texture_read")
	if independent_a.is_empty() or independent_b.is_empty() or math_variant.is_empty() \
			or texture_writer.is_empty() or texture_reader.is_empty():
		cleanup(rd)
		quit(2)
		return

	var independent_record = record_independent_lists(rd, [independent_a, independent_b])
	var dependent_record = record_dependent_chain(rd, math_variant)
	var copy_record = record_copy_boundary(rd, math_variant)
	var texture_record = record_texture_chain(rd, texture_writer, texture_reader)
	rd.submit()
	rd.sync()

	# Use the asynchronous API even for this one-shot probe. Native WebGPU
	# readback is inherently asynchronous, while the callback path also works on
	# Metal. A second local-device submit/sync executes the copies and delivers
	# every callback before verification and resource cleanup.
	request_buffer_readback(rd, "independent", independent_record.buffer)
	request_buffer_readback(rd, "dependent", dependent_record.buffer)
	request_buffer_readback(rd, "copy_source", copy_record.source)
	request_buffer_readback(rd, "copy_destination", copy_record.destination)
	request_texture_readback(rd, "texture", texture_record.texture)
	request_buffer_readback(rd, "texture_output", texture_record.output)
	rd.submit()
	rd.sync()

	verify_independent(get_readback("independent"))
	verify_dependent(get_readback("dependent"))
	verify_copy(copy_record, get_readback("copy_source"), get_readback("copy_destination"))
	verify_texture(texture_record, get_readback("texture"), get_readback("texture_output"))
	cleanup(rd)
	print("COMPUTE_ENCODER_PROBE_DONE failures=%d independent_lists=%d" % [failures, INDEPENDENT_LISTS])
	quit(0 if failures == 0 else 1)
