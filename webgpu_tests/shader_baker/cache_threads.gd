extends SceneTree

var jobs: Array[int] = []
var outcomes := [false, false, false, false]
var result_mutex := Mutex.new()
var draws := 0
var started := 0

func _initialize() -> void:
	started = Time.get_ticks_msec()
	for index in outcomes.size():
		jobs.append(WorkerThreadPool.add_task(_worker.bind(index), true))

func _process(_delta: float) -> bool:
	draws += 1
	if Time.get_ticks_msec() - started > 180000:
		push_error("CACHE_THREADS_TIMEOUT")
		quit(1)
		return false
	for job in jobs:
		if not WorkerThreadPool.is_task_completed(job): return false
	for job in jobs:
		WorkerThreadPool.wait_for_task_completion(job)
	print("CACHE_THREADS COMPLETE results=", outcomes, " frames=", draws)
	quit(0 if outcomes.all(func(value: bool) -> bool: return value) else 1)
	return false

func _worker(index: int) -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Local WebGPU rendering device unavailable")
		return
	var okay := true
	for iteration in 40:
		var expected := index * 40 + iteration + 1
		var source := RDShaderSource.new()
		source.source_compute = "#version 450\nlayout(local_size_x=1) in; layout(set=0,binding=0,std430) buffer Output { uint value; } result; void main(){result.value=%du;}" % expected
		var spirv := rd.shader_compile_spirv_from_source(source)
		var shader := rd.shader_create_from_spirv(spirv)
		var pipeline := rd.compute_pipeline_create(shader)
		var buffer := rd.storage_buffer_create(4)
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = 0
		uniform.add_id(buffer)
		var bindings := rd.uniform_set_create([uniform],shader,0)
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands,pipeline)
		rd.compute_list_bind_uniform_set(commands,bindings,0)
		rd.compute_list_dispatch(commands,1,1,1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var values := rd.buffer_get_data(buffer).to_int32_array()
		okay = okay and values.size() == 1 and values[0] == expected
		for resource in [bindings,buffer,pipeline,shader]: rd.free_rid(resource)
	rd.free()
	result_mutex.lock()
	outcomes[index] = okay
	result_mutex.unlock()
