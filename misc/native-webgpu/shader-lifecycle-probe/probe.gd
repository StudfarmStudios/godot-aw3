extends Node

const SOURCE = """#version 450
layout(local_size_x = 1) in;
layout(set = 0, binding = 0, std430) buffer Result { uint value; } result;
void main() { result.value = 42u; }
"""
var _completed := 0
var _failed := false

func _ready() -> void:
	RenderingServer.call_on_render_thread(_run)
	get_tree().create_timer(30).timeout.connect(func():
		if _completed != 2:
			push_error("SHADER_LIFECYCLE_PROBE readback timeout")
			get_tree().quit(1))

func _run() -> void:
	var rd := RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = SOURCE
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		_report.call_deferred(false, spirv.compile_error_compute)
		return

	# Free a never-used variant without translating it (see the verbose log).
	var unused := rd.shader_create_from_spirv(spirv)
	rd.set_resource_name(unused, "unused_lifecycle_probe")
	rd.free_rid(unused)

	for uniform_first in [true, false]:
		var shader := rd.shader_create_from_spirv(spirv)
		rd.set_resource_name(shader, "used_lifecycle_probe")
		var buffer := rd.storage_buffer_create(4, PackedByteArray([0, 0, 0, 0]))
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = 0
		uniform.add_id(buffer)
		var bindings: RID
		var pipeline: RID
		if uniform_first:
			bindings = rd.uniform_set_create([uniform], shader, 0)
			pipeline = rd.compute_pipeline_create(shader)
		else:
			pipeline = rd.compute_pipeline_create(shader)
			bindings = rd.uniform_set_create([uniform], shader, 0)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, bindings, 0)
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()
		var resources := [bindings, pipeline, buffer, shader]
		rd.buffer_get_data_async(buffer, func(bytes: PackedByteArray):
			var value := bytes.decode_u32(0) if bytes.size() == 4 else -1
			for rid in resources:
				rd.free_rid(rid)
			_report.call_deferred(value == 42, "uniform_first=%s value=%s" % [uniform_first, value]))

func _report(passed: bool, detail: String) -> void:
	print("SHADER_LIFECYCLE_PROBE %s %s" % ["PASS" if passed else "FAIL", detail])
	_failed = _failed or not passed
	_completed += 1
	if _completed == 2:
		get_tree().quit(1 if _failed else 0)
