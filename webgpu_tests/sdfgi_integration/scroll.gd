extends SceneTree
var directory := ""
var rd: RenderingDevice
var owned: Array[RID] = []
const N := 16
const BYTE_COUNT := 8*N*N*N
func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fixture-dir="): directory=a.trim_prefix("--fixture-dir=")
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
	if rd==null:
		quit(2)
		return
	var source := RDShaderSource.new()
	source.source_compute=FileAccess.get_file_as_string(directory.path_join("scroll.comp"))
	var spirv := rd.shader_compile_spirv_from_source(source,false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(2)
		return
	var shader:=own(rd.shader_create_from_spirv(spirv))
	var pipeline:=own(rd.compute_pipeline_create(shader))
	var tf:=RDTextureFormat.new()
	tf.texture_type=RenderingDevice.TEXTURE_TYPE_3D
	tf.format=RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.width=2*N
	tf.height=N
	tf.depth=2*N
	tf.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var texture:=own(rd.texture_create(tf,RDTextureView.new(),[FileAccess.get_file_as_bytes(directory.path_join("source.rgba8"))]))
	var initial:=PackedByteArray()
	initial.resize(BYTE_COUNT+64)
	initial.fill(90)
	var buffer:=own(rd.storage_buffer_create(initial.size(),initial))
	var bindings:=own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,buffer),uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,2,texture)],shader,0))
	if not bindings.is_valid() or not pipeline.is_valid():
		quit(2)
		return
	var cases:Array=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("cases.json")))
	for case in cases:
		rd.buffer_update(buffer,0,initial.size(),initial)
		var pc:=PackedByteArray()
		pc.resize(48)
		for axis in 3:pc.encode_s32(axis*4,int(case.scroll[axis]))
		pc.encode_s32(12,N)
		pc.encode_s32(40,int(case.cascade))
		var commands:=rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands,pipeline)
		rd.compute_list_bind_uniform_set(commands,bindings,0)
		rd.compute_list_set_push_constant(commands,pc,pc.size())
		rd.compute_list_dispatch(commands,(N-absi(int(case.scroll[0]))+3)/4,(N-absi(int(case.scroll[1]))+3)/4,(N-absi(int(case.scroll[2]))+3)/4)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var file:=FileAccess.open(directory.path_join(case.name+".actual"),FileAccess.WRITE)
		file.store_buffer(rd.buffer_get_data(buffer))
		file.close()
	for i in range(owned.size()-1,-1,-1):rd.free_rid(owned[i])
	rd.free()
	print("SDFGI_SCROLL COMPLETE cases=%d"%cases.size())
	quit(0)
