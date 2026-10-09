extends SceneTree
var directory := ""
var rd: RenderingDevice
var owned: Array[RID] = []
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fixture-dir="): directory=arg.trim_prefix("--fixture-dir=")
	call_deferred("_run")
func own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	return rid
func uniform(kind: int,binding: int,rid: RID) -> RDUniform:
	var u:=RDUniform.new()
	u.uniform_type=kind
	u.binding=binding
	u.add_id(rid)
	return u
func _run() -> void:
	rd=RenderingServer.create_local_rendering_device()
	var source:=RDShaderSource.new()
	source.source_compute=FileAccess.get_file_as_string(directory.path_join("scroll.comp"))
	var spirv:=rd.shader_compile_spirv_from_source(source,false)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(2)
		return
	var shader:=own(rd.shader_create_from_spirv(spirv))
	var pipeline:=own(rd.compute_pipeline_create(shader))
	var textures: Array[RID]=[]
	for format in [RenderingDevice.DATA_FORMAT_R16_UINT,RenderingDevice.DATA_FORMAT_R32_UINT,RenderingDevice.DATA_FORMAT_R32_UINT]:
		var tf:=RDTextureFormat.new()
		tf.texture_type=RenderingDevice.TEXTURE_TYPE_3D
		tf.width=16
		tf.height=16
		tf.depth=16
		tf.format=format
		tf.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		textures.append(own(rd.texture_create(tf,RDTextureView.new())))
	var zero:=PackedByteArray()
	zero.resize(16)
	var count:=PackedInt32Array([4,1,1,256]).to_byte_array()
	var counter:=own(rd.storage_buffer_create(16,count))
	var indirect:=own(rd.storage_buffer_create(16,zero,RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT))
	var facing:=own(rd.storage_buffer_create(16*16*16*4))
	var input:=FileAccess.get_file_as_bytes(directory.path_join("voxels.bin"))
	var voxels:=own(rd.storage_buffer_create(input.size(),input))
	var bindings:=own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,textures[0]),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,2,facing),uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,3,textures[1]),uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,4,textures[2]),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,5,counter),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,6,voxels)],shader,0))
	var pc:=PackedInt32Array([3,-2,1,16,0,0,0,0,0,0,0,0]).to_byte_array()
	var fill_source:=RDShaderSource.new()
	fill_source.source_compute="#version 450\nlayout(local_size_x=64) in; layout(set=0,binding=0,std430) buffer Count { uvec4 value; } dst; void main() { if(gl_GlobalInvocationID.x == 0u) dst.value=uvec4(4,1,1,256); }"
	var fill_shader:=own(rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(fill_source,false)))
	var fill_pipeline:=own(rd.compute_pipeline_create(fill_shader))
	var fill_set:=own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,0,counter)],fill_shader,0))
	var jf_source:=RDShaderSource.new()
	jf_source.source_compute=FileAccess.get_file_as_string(directory.path_join("initialize.comp"))
	var jf_shader:=own(rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(jf_source,false)))
	var jf_pipeline:=own(rd.compute_pipeline_create(jf_shader))
	var jf_format:=RDTextureFormat.new()
	jf_format.texture_type=RenderingDevice.TEXTURE_TYPE_3D
	jf_format.width=16
	jf_format.height=16
	jf_format.depth=16
	jf_format.format=RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
	jf_format.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var jf_texture:=own(rd.texture_create(jf_format,RDTextureView.new()))
	var jf_set:=own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,textures[0]),uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,2,jf_texture)],jf_shader,0))
	var failed:=0
	for mode in 8:
		for texture in textures:rd.texture_clear(texture,Color(0,0,0,0),0,1,0,1)
		rd.buffer_clear(facing,0,16*16*16*4)
		if mode < 4: rd.buffer_update(counter,0,16,count)
		else:
			var fill_commands:=rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(fill_commands,fill_pipeline)
			rd.compute_list_bind_uniform_set(fill_commands,fill_set,0)
			rd.compute_list_dispatch(fill_commands,1,1,1)
			rd.compute_list_end()
		rd.buffer_copy(counter,indirect,0,0,16)
		var commands:=rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands,pipeline)
		rd.compute_list_bind_uniform_set(commands,bindings,0)
		rd.compute_list_set_push_constant(commands,pc,pc.size())
		if mode%2==0:rd.compute_list_dispatch(commands,4,1,1)
		else:rd.compute_list_dispatch_indirect(commands,indirect,0)
		rd.compute_list_add_barrier(commands)
		rd.compute_list_bind_compute_pipeline(commands,jf_pipeline)
		rd.compute_list_bind_uniform_set(commands,jf_set,0)
		rd.compute_list_set_push_constant(commands,pc,pc.size())
		rd.compute_list_dispatch(commands,4,4,4)
		rd.compute_list_end()
		if mode%4>=2:rd.buffer_update(counter,0,16,zero)
		rd.submit()
		rd.sync()
		var values: Array[PackedByteArray]=[rd.texture_get_data(textures[0],0),rd.buffer_get_data(facing),rd.texture_get_data(textures[1],0),rd.texture_get_data(textures[2],0)]
		var jf_data:=rd.texture_get_data(jf_texture,0)
		var jf_good:=true
		for i in 4096:
			var solid:=values[0].decode_u16(i*2)!=0
			var expected_voxel:=((i%16)|(((i/16) as int)%16)<<8|((i/256) as int)<<16|255<<24) if solid else 0
			if jf_data.decode_u32(i*4)!=expected_voxel:
				jf_good=false
		if not jf_good:failed+=1
		print("VOXEL_SCROLL mode=%d field=jumpflood-readback good=%s"%[mode,str(jf_good)])
		var names:=["albedo","facing","light","aniso"]
		for i in 4:
			var expected:=FileAccess.get_file_as_bytes(directory.path_join(names[i]+".expected"))
			var good:=values[i]==expected
			if not good:failed+=1
			print("VOXEL_SCROLL mode=%d field=%s good=%s bytes=%d"%[mode,names[i],str(good),values[i].size()])
	for i in range(owned.size()-1,-1,-1):rd.free_rid(owned[i])
	rd.free()
	print("VOXEL_SCROLL COMPLETE checks=40 failed=%d"%failed)
	quit(0 if failed==0 else 1)
