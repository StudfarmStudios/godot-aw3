extends SceneTree

# Actual GPU tests of the production callbacks, including read/reset and guards.
const WIDTH := 13
const HEIGHT := 7
const PIXELS := WIDTH * HEIGHT
const GUARD_WORDS := 16
const GUARD := 0x3eaaaaaa
const EXPECTED_CHECKS := 144
var rd: RenderingDevice
var owned: Array[RID] = []
var pipelines: Array[RID] = []
var sets: Array[RID] = []
var sampler_sets: Array[RID] = []
var depth: RID
var output: RID
var constants: RID
var passed := 0
var failed := 0
var shader_directory := ""

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shader-dir="):
			shader_directory = argument.trim_prefix("--shader-dir=")
	call_deferred("_run")

func _own(id: RID) -> RID:
	if id.is_valid():
		owned.append(id)
	return id

func _result(label: String, success: bool, details: String = "") -> void:
	if success:
		passed += 1
	else:
		failed += 1
	print("FSR2_ATOMIC %s %s %s" % ["PASS" if success else "FAIL", label, details])

func _uniform(type: int, binding: int, resource: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(resource)
	return uniform

func _setup(inverted: int) -> bool:
	var initial := PackedByteArray()
	initial.resize((PIXELS + GUARD_WORDS) * 4)
	for index in PIXELS + GUARD_WORDS:
		initial.encode_u32(index * 4, GUARD)
	depth = _own(rd.storage_buffer_create(initial.size(), initial))
	output = _own(rd.storage_buffer_create((PIXELS + 8) * 4))
	var cb := PackedByteArray()
	cb.resize(192) # Exact std140 Fsr2Constants layout from the production header.
	cb.encode_s32(0, 9)
	cb.encode_s32(4, 5)
	cb.encode_s32(8, WIDTH)
	cb.encode_s32(12, HEIGHT)
	constants = _own(rd.uniform_buffer_create(cb.size(), cb))
	# The unmodified callbacks declare both samplers. RD reflection retains
	# those bindings even though this focused shader never samples an image.
	var point := _own(rd.sampler_create(RDSamplerState.new()))
	var linear_state := RDSamplerState.new()
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	var linear := _own(rd.sampler_create(linear_state))
	for operation in 5:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(shader_directory.path_join("depth_%d_%d.glsl" % [inverted, operation]))
		if source.source_compute.is_empty():
			push_error("Missing preprocessed production callback shader")
			return false
		var spirv := rd.shader_compile_spirv_from_source(source, false)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			return false
		var shader := _own(rd.shader_create_from_spirv(spirv))
		if not shader.is_valid():
			return false
		var sampler_set := _own(rd.uniform_set_create([
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 0, point),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 1, linear)], shader, 0))
		var pipeline := _own(rd.compute_pipeline_create(shader))
		var uniforms: Array[RDUniform] = [_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, constants)]
		if operation == 4:
			uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, depth))
			uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, output))
		else:
			uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, depth))
		var uniform_set := _own(rd.uniform_set_create(uniforms, shader, 1))
		if not pipeline.is_valid() or not uniform_set.is_valid() or not sampler_set.is_valid():
			return false
		pipelines.append(pipeline)
		sets.append(uniform_set)
		sampler_sets.append(sampler_set)
	return true

func _record(operation: int, phase: int, seed: int, reset: float) -> void:
	var params := PackedByteArray()
	params.resize(16)
	params.encode_u32(0, phase)
	params.encode_u32(4, seed)
	params.encode_float(8, reset)
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, pipelines[operation])
	rd.compute_list_bind_uniform_set(commands, sampler_sets[operation], 0)
	rd.compute_list_bind_uniform_set(commands, sets[operation], 1)
	rd.compute_list_set_push_constant(commands, params, params.size())
	var count: int = PIXELS * 4096 if operation == 1 else (PIXELS + 8 if operation == 4 else PIXELS)
	rd.compute_list_dispatch(commands, (count + 63) / 64, 1, 1)
	rd.compute_list_end()

func _check(label: String, expected: float, phase: int, seed: int, reset: float) -> void:
	_record(4, phase, seed, reset)
	rd.submit()
	rd.sync()
	var actual := rd.buffer_get_data(output)
	var raw := rd.buffer_get_data(depth)
	var values_match := actual.size() == (PIXELS + 8) * 4 and raw.size() == (PIXELS + GUARD_WORDS) * 4
	var detail := ""
	if values_match:
		for index in PIXELS:
			if actual.decode_float(index * 4) != expected or raw.decode_float(index * 4) != expected:
				values_match = false
				detail = "pixel=%d callback=%f raw=%f expected=%f" % [index, actual.decode_float(index * 4), raw.decode_float(index * 4), expected]
				break
	_result(label + " values", values_match, detail)
	var oob_zero := actual.size() == (PIXELS + 8) * 4
	if oob_zero:
		for index in 8:
			oob_zero = oob_zero and actual.decode_u32((PIXELS + index) * 4) == 0
	_result(label + " OOB reads zero", oob_zero)
	var guards_intact := raw.size() == (PIXELS + GUARD_WORDS) * 4
	if guards_intact:
		for index in GUARD_WORDS:
			guards_intact = guards_intact and raw.decode_u32((PIXELS + index) * 4) == GUARD
	_result(label + " adjacent guard words", guards_intact)

func _cleanup() -> void:
	for index in range(owned.size() - 1, -1, -1):
		rd.free_rid(owned[index])
	owned.clear()
	pipelines.clear()
	sets.clear()
	sampler_sets.clear()

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Native WebGPU RenderingDevice unavailable")
		quit(2)
		return
	print("FSR2_ATOMIC adapter=%s vendor=%s engine=%s" % [rd.get_device_name(), rd.get_device_vendor_name(), Engine.get_version_info().hash])
	for inverted in 2:
		if not _setup(inverted):
			_cleanup()
			rd.free()
			quit(2)
			return
		var reset := 0.0 if inverted == 1 else 1.0
		for cycle in 6:
			var phase := cycle % 2
			var label := "inverted=%d cycle=%d" % [inverted, cycle]
			_record(0, phase, cycle, reset)
			_check(label + " reset", reset, phase, cycle, reset)
			_record(2, phase, cycle, reset)
			_check(label + " OOB Set", reset, phase, cycle, reset)
			_record(1, phase, cycle, reset)
			var nearest := 0.125 if phase == 0 else 0.25
			if inverted == 1:
				nearest += 4095.0 / (8192.0 if phase == 0 else 16384.0)
			_check(label + " 4096 writers/texel", nearest, phase, cycle, reset)
			_record(3, phase, cycle, reset)
			_check(label + " OOB Store", nearest, phase, cycle, reset)
		_cleanup()
	rd.free()
	print("FSR2_ATOMIC COMPLETE passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 and passed == EXPECTED_CHECKS else 1)
