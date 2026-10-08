extends SceneTree
var rd: RenderingDevice
var directory := ""
var owned: Array[RID] = []
const N := 8
const COUNT := N * N * N
const GUARD := 0x3ea5a5a5

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture-dir="): directory = argument.trim_prefix("--fixture-dir=")
	call_deferred("_run")
func own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	return rid
func uniform(kind: int,binding: int,rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type=kind
	u.binding=binding
	u.add_id(rid)
	return u
func _run() -> void:
	rd=RenderingServer.create_local_rendering_device()
	if rd == null:
		quit(2)
		return
	var source := RDShaderSource.new()
	source.source_compute=FileAccess.get_file_as_string(directory.path_join("facing.comp"))
	var spirv := rd.shader_compile_spirv_from_source(source,false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(2)
		return
	var shader := own(rd.shader_create_from_spirv(spirv))
	var pipeline := own(rd.compute_pipeline_create(shader))
	var initial := PackedByteArray()
	initial.resize((COUNT + 16)*4)
	for index in 16: initial.encode_u32((COUNT+index)*4,GUARD)
	var facing := own(rd.storage_buffer_create(initial.size(),initial))
	var tf := RDTextureFormat.new()
	tf.texture_type=RenderingDevice.TEXTURE_TYPE_3D
	tf.format=RenderingDevice.DATA_FORMAT_R16_UINT
	tf.width=N
	tf.height=N
	tf.depth=N
	tf.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var color := own(rd.texture_create(tf,RDTextureView.new()))
	var bindings := own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,24,color),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,27,facing)],shader,1))
	if not bindings.is_valid() or not pipeline.is_valid():
		quit(2)
		return
	var failed := 0
	for cycle in 6:
		rd.buffer_update(facing,0,initial.size(),initial)
		for mode in 2:
			var pc := PackedByteArray()
			pc.resize(16)
			pc.encode_u32(0,cycle%2)
			pc.encode_u32(4,mode)
			var commands := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(commands,pipeline)
			rd.compute_list_bind_uniform_set(commands,bindings,1)
			rd.compute_list_set_push_constant(commands,pc,pc.size())
			rd.compute_list_dispatch(commands,32768 if mode == 0 else 64,1,1)
			rd.compute_list_end()
			rd.submit()
			rd.sync()
			var data := rd.buffer_get_data(facing)
			var expected := 63 if cycle%2 == 0 else 21
			var wrong := 0
			for index in COUNT:
				if data.decode_u32(index*4) != expected: wrong += 1
			for index in 16:
				if data.decode_u32((COUNT+index)*4) != GUARD: wrong += 1
			if wrong: failed += 1
			print("SDFGI_FACING %s cycle=%d mode=%d wrong=%d" % ["FAIL" if wrong else "PASS",cycle,mode,wrong])
	for index in range(owned.size()-1,-1,-1): rd.free_rid(owned[index])
	rd.free()
	print("SDFGI_FACING COMPLETE checks=12 failed=%d" % failed)
	quit(0 if failed == 0 else 1)
