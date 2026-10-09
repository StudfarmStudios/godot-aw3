extends SceneTree
var rd: RenderingDevice
var owned: Array[RID]=[]
var checks:=0
var failed:=0
func _initialize() -> void: call_deferred("_run")
func own(r:RID)->RID:
	if r.is_valid():owned.append(r)
	return r
func uniform(kind:int,binding:int,r:RID)->RDUniform:
	var u:=RDUniform.new()
	u.uniform_type=kind
	u.binding=binding
	u.add_id(r)
	return u
func check(good:bool,label:String)->void:
	checks+=1
	if not good:failed+=1
	print("TEXTURE_CLEAR %s %s"%["PASS" if good else "FAIL",label])
func texture(format:int,w:int,h:int,d:int,mips:int,storage:bool=false)->RID:
	var f:=RDTextureFormat.new()
	f.texture_type=RenderingDevice.TEXTURE_TYPE_3D
	f.width=w
	f.height=h
	f.depth=d
	f.mipmaps=mips
	f.format=format
	f.usage_bits=RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT|RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	if storage:f.usage_bits|=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return own(rd.texture_create(f,RDTextureView.new()))
func pixel(encoding:String,channels:int,c:Color)->PackedByteArray:
	var b:=PackedByteArray()
	var values:=[c.r,c.g,c.b,c.a]
	if encoding=="bgra8" or encoding=="bgra8srgb":values=[c.b,c.g,c.r,c.a]
	if encoding.ends_with("srgb"):
		for i in 3:
			values[i]=12.92*values[i] if values[i]<0.0031308 else 1.055*pow(values[i],1.0/2.4)-0.055
	if encoding=="rgb10a2" or encoding=="rgb10a2u" or encoding=="rg11b10":
		b.resize(4)
		var packed:=0
		if encoding=="rg11b10":
			for i in 3:
				var h:=PackedByteArray()
				h.resize(2)
				h.encode_half(0,values[i])
				packed|=(h.decode_u16(0)>>(5 if i==2 else 4))<<([0,11,22][i])
		else:
			for i in 4:
				var maximum:=3 if i==3 else 1023
				packed|=(int(round(clampf(values[i],0,1)*maximum)) if encoding=="rgb10a2" else int(clampf(values[i],0,maximum)))<<(i*10)
		b.encode_u32(0,packed)
		return b
	for i in channels:
		var v:float=values[i]
		match encoding:
			"u8":b.append(int(clampf(v,0,255)))
			"i8":b.append(int(clampf(v,-128,127))&255)
			"unorm8","rgba8srgb","bgra8","bgra8srgb":b.append(int(round(clampf(v,0,1)*255)))
			"snorm8":b.append(int(round(clampf(v,-1,1)*127))&255)
			"u16","i16":
				var n:=b.size()
				b.resize(n+2)
				b.encode_u16(n,int(v)&65535)
			"u32","i32":
				var n:=b.size()
				b.resize(n+4)
				b.encode_u32(n,int(v)&0xffffffff)
			"f32":
				var n:=b.size()
				b.resize(n+4)
				b.encode_float(n,v)
			"f16":
				var n:=b.size()
				b.resize(n+2)
				b.encode_half(n,v)
	return b
func encoding_case(format:int,encoding:String,channels:int,color:Color,storage:bool=false)->void:
	var t:=texture(format,13,9,5,4,storage)
	var expected_pixel:=pixel(encoding,channels,color)
	for mode in 3:
		# Re-prime nonzero data before a zero/subrange clear; a fresh texture alone
		# would let a broken zero-clear implementation pass.
		var primed:=PackedByteArray()
		primed.resize(640*expected_pixel.size())
		primed.fill(85)
		rd.texture_update(t,0,primed)
		rd.submit()
		rd.sync()
		var before:=rd.texture_get_data(t,0)
		if mode==0:check(before==primed,"prime-full-volume-format=%d"%format)
		var zero:=mode==0
		rd.texture_clear(t,Color(0,0,0,0) if zero else color,1 if mode==2 else 0,2 if mode==2 else 4,0,1)
		rd.submit()
		rd.sync()
		var actual:=rd.texture_get_data(t,0)
		var expected:=before.duplicate()
		var offset:=0
		for mip in 4:
			var count:=maxi(13>>mip,1)*maxi(9>>mip,1)*maxi(5>>mip,1)
			for i in count:
				if mode!=2 or mip==1 or mip==2:
					for channel_byte in expected_pixel.size():expected[offset+channel_byte]=0 if zero else expected_pixel[channel_byte]
				offset+=expected_pixel.size()
		check(actual==expected,"format=%d mode=%d bytes=%d"%[format,mode,actual.size()])
func ordered_case()->void:
	var t:=texture(RenderingDevice.DATA_FORMAT_R32_UINT,13,9,5,1,true)
	var output:=own(rd.storage_buffer_create(13*9*5*4*3))
	var src:=RDShaderSource.new()
	src.source_compute="#version 450\nlayout(local_size_x=4,local_size_y=4,local_size_z=4) in; layout(r32ui,set=0,binding=0) uniform readonly uimage3D tex; layout(set=0,binding=1,std430) buffer Output { uint values[]; } data; layout(push_constant) uniform P { uint offset; } pc; void main(){ivec3 p=ivec3(gl_GlobalInvocationID); if(any(greaterThanEqual(p,ivec3(13,9,5))))return; uint i=uint((p.z*9+p.y)*13+p.x);data.values[pc.offset+i]=imageLoad(tex,p).x;}"
	var spv:=rd.shader_compile_spirv_from_source(src,false)
	if not spv.compile_error_compute.is_empty():push_error(spv.compile_error_compute)
	var shader:=own(rd.shader_create_from_spirv(spv))
	var pipeline:=own(rd.compute_pipeline_create(shader))
	var us:=own(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,t),uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,output)],shader,0))
	for i in 3:
		rd.texture_clear(t,Color([7,3,0][i],0,0,0),0,1,0,1)
		var c:=rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(c,pipeline)
		rd.compute_list_bind_uniform_set(c,us,0)
		var pc:=PackedInt32Array([i*13*9*5]).to_byte_array()
		rd.compute_list_set_push_constant(c,pc,4)
		rd.compute_list_dispatch(c,4,3,2)
		rd.compute_list_end()
	rd.submit()
	rd.sync()
	var data:=rd.buffer_get_data(output)
	for i in 3:
		var good:=true
		for j in 13*9*5:
			if data.decode_u32((i*13*9*5+j)*4)!=[7,3,0][i]:good=false
		check(good,"ordered-clear-read-%d"%i)
func array_case()->void:
	var f:=RDTextureFormat.new()
	f.texture_type=RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	f.width=13
	f.height=9
	f.array_layers=4
	f.mipmaps=4
	f.format=RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	f.usage_bits=RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT|RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial:Array[PackedByteArray]=[]
	for layer in 4:
		var data:=PackedByteArray()
		data.resize(148*4)
		data.fill(17+layer)
		initial.append(data)
	var t:=own(rd.texture_create(f,RDTextureView.new(),initial))
	rd.texture_clear(t,Color(0.25,0.5,0.75,1),1,2,1,2)
	var view:=own(rd.texture_create_shared_from_slice(RDTextureView.new(),t,2,2,1,RenderingDevice.TEXTURE_SLICE_2D))
	rd.texture_clear(view,Color(1,0,0,1),0,1,0,1)
	rd.submit()
	rd.sync()
	for layer in 4:
		var expected:=initial[layer].duplicate()
		for i in 148:
			var value:=PackedByteArray()
			if layer==1 or layer==2:
				if i>=117 and i<147:value=PackedByteArray([64,128,191,255])
			if layer==2 and i>=141 and i<147:value=PackedByteArray([255,0,0,255])
			for j in value.size():expected[i*4+j]=value[j]
		check(rd.texture_get_data(t,layer)==expected,"array-layer-mip-preservation-%d"%layer)
func large_case()->void:
	var t:=texture(RenderingDevice.DATA_FORMAT_R32_UINT,257,129,33,1)
	for value in [7,0]:
		rd.texture_clear(t,Color(value,0,0,0),0,1,0,1)
		rd.submit()
		rd.sync()
		var bytes:=rd.texture_get_data(t,0)
		var good:=bytes.size()==257*129*33*4
		for i in 257*129*33:
			if bytes.decode_u32(i*4)!=value:good=false
		check(good,"bounded-upload-depth-chunks-value-%d"%value)
func _run()->void:
	rd=RenderingServer.create_local_rendering_device()
	var cases:=[
		[RenderingDevice.DATA_FORMAT_R8_UINT,"u8",1],[RenderingDevice.DATA_FORMAT_R8G8_UINT,"u8",2],[RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT,"u8",4],
		[RenderingDevice.DATA_FORMAT_R8_SINT,"i8",1],[RenderingDevice.DATA_FORMAT_R8G8_SINT,"i8",2],[RenderingDevice.DATA_FORMAT_R8G8B8A8_SINT,"i8",4],
		[RenderingDevice.DATA_FORMAT_R16_UINT,"u16",1],[RenderingDevice.DATA_FORMAT_R16G16_UINT,"u16",2],[RenderingDevice.DATA_FORMAT_R16G16B16A16_UINT,"u16",4],
		[RenderingDevice.DATA_FORMAT_R16_SINT,"i16",1],[RenderingDevice.DATA_FORMAT_R16G16_SINT,"i16",2],[RenderingDevice.DATA_FORMAT_R16G16B16A16_SINT,"i16",4],
		[RenderingDevice.DATA_FORMAT_R32_UINT,"u32",1],[RenderingDevice.DATA_FORMAT_R32G32_UINT,"u32",2],[RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT,"u32",4],
		[RenderingDevice.DATA_FORMAT_R32_SINT,"i32",1],[RenderingDevice.DATA_FORMAT_R32G32_SINT,"i32",2],[RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT,"i32",4],
		[RenderingDevice.DATA_FORMAT_R8_UNORM,"unorm8",1],[RenderingDevice.DATA_FORMAT_R8G8_UNORM,"unorm8",2],[RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,"unorm8",4],
		[RenderingDevice.DATA_FORMAT_R8_SNORM,"snorm8",1],[RenderingDevice.DATA_FORMAT_R8G8_SNORM,"snorm8",2],[RenderingDevice.DATA_FORMAT_R8G8B8A8_SNORM,"snorm8",4],
		[RenderingDevice.DATA_FORMAT_R16_SFLOAT,"f16",1],[RenderingDevice.DATA_FORMAT_R16G16_SFLOAT,"f16",2],[RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,"f16",4],
		[RenderingDevice.DATA_FORMAT_R32_SFLOAT,"f32",1],[RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,"f32",2],[RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,"f32",4]]
	for test in cases:
		var signed:=str(test[1]).begins_with("i")
		var integer:bool=signed or str(test[1]).begins_with("u") and test[1]!="unorm8"
		encoding_case(test[0],test[1],test[2],Color(-7,12,-15,20) if signed else (Color(7,12,15,20) if integer else Color(0.25,0.5,0.75,1)))
	for test in [[RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB,"rgba8srgb"],[RenderingDevice.DATA_FORMAT_B8G8R8A8_UNORM,"bgra8"],[RenderingDevice.DATA_FORMAT_B8G8R8A8_SRGB,"bgra8srgb"],[RenderingDevice.DATA_FORMAT_A2B10G10R10_UNORM_PACK32,"rgb10a2"],[RenderingDevice.DATA_FORMAT_A2B10G10R10_UINT_PACK32,"rgb10a2u"],[RenderingDevice.DATA_FORMAT_B10G11R11_UFLOAT_PACK32,"rg11b10"]]:
		encoding_case(test[0],test[1],4,Color(7,12,15,2) if test[1]=="rgb10a2u" else Color(0.25,0.5,0.75,0.5))
	ordered_case()
	array_case()
	large_case()
	for i in range(owned.size()-1,-1,-1):rd.free_rid(owned[i])
	rd.free()
	print("TEXTURE_CLEAR COMPLETE checks=%d failed=%d"%[checks,failed])
	quit(0 if failed==0 else 1)
