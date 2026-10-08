extends SceneTree

# Dispatch the unmodified production propagation kernel on a local WebGPU device.
var rd: RenderingDevice
var owned: Array[RID] = []
var directory := ""
var texture_reference := false
var occlusion_textures: Array[RID] = []
const N := 16
const VOXELS := N * N * N
const BYTES := VOXELS * 8
const GUARD := 0x5a

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--texture-reference": texture_reference = true
		if argument.begins_with("--fixture-dir="):
			directory = argument.trim_prefix("--fixture-dir=")
	call_deferred("_run")

func own(rid: RID) -> RID:
	if rid.is_valid():
		owned.append(rid)
	return rid

func uniform(kind: int, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = kind
	u.binding = binding
	u.add_id(rid)
	return u

func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		quit(2)
		return
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(directory.path_join("occlusion.comp"))
	var spirv := rd.shader_compile_spirv_from_source(source, false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(2)
		return
	var shader := own(rd.shader_create_from_spirv(spirv))
	var pipeline := own(rd.compute_pipeline_create(shader))
	var facing := own(rd.storage_buffer_create(VOXELS * 4))
	var initial := PackedByteArray()
	initial.resize(BYTES + 64)
	initial.fill(GUARD)
	var occlusion := own(rd.storage_buffer_create(initial.size(), initial))
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.format = RenderingDevice.DATA_FORMAT_R16_UINT
	tf.width = N
	tf.height = N
	tf.depth = N
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var color := own(rd.texture_create(tf, RDTextureView.new()))
	var uniforms: Array[RDUniform]
	if texture_reference:
		tf.format = RenderingDevice.DATA_FORMAT_R32_UINT
		tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		facing = own(rd.texture_create(tf,RDTextureView.new()))
		tf.format = RenderingDevice.DATA_FORMAT_R8_UNORM
		tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		var occlusion_uniform := RDUniform.new()
		occlusion_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		occlusion_uniform.binding = 2
		for i in 8:
			var texture := own(rd.texture_create(tf,RDTextureView.new()))
			occlusion_textures.append(texture)
			occlusion_uniform.add_id(texture)
		uniforms = [uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,color),occlusion_uniform,uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,3,facing)]
	else:
		uniforms = [uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,color),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,2,occlusion),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,3,facing)]
	var bindings := own(rd.uniform_set_create(uniforms,shader,0))
	if not pipeline.is_valid() or not bindings.is_valid():
		quit(2)
		return
	var cases: Array = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("cases.json")))
	var completed := 0
	for case in cases:
		var data := FileAccess.get_file_as_bytes(directory.path_join(case.name + ".facing"))
		if texture_reference: rd.texture_update(facing,0,data)
		else: rd.buffer_update(facing,0,data.size(),data)
		rd.buffer_update(occlusion, 0, initial.size(), initial)
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands, pipeline)
		rd.compute_list_bind_uniform_set(commands, bindings, 0)
		for slice in 8:
			var pc := PackedByteArray()
			pc.resize(48)
			pc.encode_s32(12, N)
			var offset := Vector3i((slice ^ int(case.parity)) & 1, ((slice ^ int(case.parity)) >> 1) & 1, ((slice ^ int(case.parity)) >> 2) & 1)
			pc.encode_s32(16, offset.x)
			pc.encode_s32(20, offset.y)
			pc.encode_s32(24, offset.z)
			pc.encode_u32(36, slice)
			rd.compute_list_set_push_constant(commands, pc, pc.size())
			rd.compute_list_dispatch(commands, 2 - offset.x, 2 - offset.y, 2 - offset.z)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var actual := PackedByteArray()
		if texture_reference:
			for texture in occlusion_textures:
				actual.append_array(rd.texture_get_data(texture,0))
			var guard := PackedByteArray()
			guard.resize(64)
			guard.fill(GUARD)
			actual.append_array(guard)
		else: actual = rd.buffer_get_data(occlusion)
		var file := FileAccess.open(directory.path_join(case.name + ".actual"), FileAccess.WRITE)
		file.store_buffer(actual)
		file.close()
		completed += 1
		print("SDFGI_OCCLUSION case=%s bytes=%d" % [case.name, actual.size()])
	for index in range(owned.size() - 1, -1, -1):
		rd.free_rid(owned[index])
	rd.free()
	print("SDFGI_OCCLUSION COMPLETE cases=%d" % completed)
	quit(0)
