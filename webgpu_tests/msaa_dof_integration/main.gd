extends Node
const Probe = preload("res://probe.gd")
var viewport: SubViewport
var camera: Camera3D
var attributes: CameraAttributesPractical
var probe: CompositorEffect
var panels: Array[MeshInstance3D] = []
var coverage_marker: MeshInstance3D
var passed := 0
var failed := 0
var captures: Array[Dictionary] = []
var output_directory := ""
var rd: RenderingDevice
var shaders: Array[RID] = []
var pipelines: Array[RID] = []
var sampler: RID
var readback: PackedFloat32Array
var read_complete := false

func _ready() -> void:
	RenderingServer.render_loop_enabled = false
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--effects-output="): output_directory = argument.trim_prefix("--effects-output=")
	RenderingServer.call_on_render_thread(_setup_reader)
	viewport = SubViewport.new()
	viewport.size = Vector2i(320,240)
	viewport.own_world_3d = true
	viewport.use_hdr_2d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.0
	camera.fov = 60.0
	camera.near = 0.1
	camera.far = 100.0
	camera.position.z = 10.0
	attributes = CameraAttributesPractical.new()
	attributes.dof_blur_near_distance = 4.0
	attributes.dof_blur_near_transition = 1.0
	attributes.dof_blur_far_distance = 8.0
	attributes.dof_blur_far_transition = 1.0
	attributes.dof_blur_amount = 0.25
	camera.attributes = attributes
	viewport.add_child(camera)
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.2,0.2,0.2)
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	probe = Probe.new()
	environment.compositor = Compositor.new()
	environment.compositor.compositor_effects = [probe]
	viewport.add_child(environment)
	for index in 3:
		var panel := MeshInstance3D.new()
		panel.mesh = QuadMesh.new()
		panel.mesh.size = Vector2(1.5,3.0)
		panel.position = Vector3((index-1)*2.0,0,[7.0,4.0,0.0][index])
		var material := ShaderMaterial.new()
		material.shader = Shader.new()
		material.shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled;
void fragment(){float a=mod(floor(UV.x*16.0)+floor(UV.y*32.0),2.0);ALBEDO=vec3(a);}
"""
		panel.material_override = material
		viewport.add_child(panel)
		panels.append(panel)
	# A slanted opaque edge exercises geometric sample coverage separately
	# from the checkerboards used to measure depth-dependent blur.
	coverage_marker = MeshInstance3D.new()
	coverage_marker.mesh = QuadMesh.new()
	coverage_marker.mesh.size = Vector2(0.8,0.6)
	coverage_marker.position = Vector3(0,2.25,4.0)
	coverage_marker.rotation.z = 0.29
	var marker_material := ShaderMaterial.new()
	marker_material.shader = Shader.new()
	marker_material.shader.code = "shader_type spatial; render_mode unshaded,cull_disabled; void fragment(){ALBEDO=vec3(1.0);}"
	coverage_marker.material_override = marker_material
	viewport.add_child(coverage_marker)
	var groups := [
		["ortho_1",Viewport.MSAA_DISABLED,Vector2i(320,240),true,false,RenderingServer.DOF_BOKEH_HEXAGON],
		["ortho_2",Viewport.MSAA_2X,Vector2i(320,240),true,false,RenderingServer.DOF_BOKEH_HEXAGON],
		["ortho_4",Viewport.MSAA_4X,Vector2i(320,240),true,false,RenderingServer.DOF_BOKEH_HEXAGON],
		["ortho_8",Viewport.MSAA_8X,Vector2i(320,240),true,false,RenderingServer.DOF_BOKEH_HEXAGON],
		["odd_hdr",Viewport.MSAA_4X,Vector2i(323,243),true,false,RenderingServer.DOF_BOKEH_HEXAGON],
		["odd_sdr",Viewport.MSAA_4X,Vector2i(323,243),false,false,RenderingServer.DOF_BOKEH_HEXAGON],
		["perspective",Viewport.MSAA_4X,Vector2i(320,240),true,true,RenderingServer.DOF_BOKEH_HEXAGON],
		["box",Viewport.MSAA_4X,Vector2i(320,240),true,false,RenderingServer.DOF_BOKEH_BOX],
		["circle",Viewport.MSAA_4X,Vector2i(320,240),true,false,RenderingServer.DOF_BOKEH_CIRCLE]]
	for group: Array in groups:
		var label: String = group[0]
		viewport.msaa_3d = group[1]
		viewport.size = group[2]
		viewport.use_hdr_2d = group[3]
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE if group[4] else Camera3D.PROJECTION_ORTHOGONAL
		for index in 3:
			var scale_factor: float = ([3.0,6.0,10.0][index] * tan(deg_to_rad(30.0)) / 3.0) if group[4] else 1.0
			panels[index].position.x = (index-1)*2.0*scale_factor
			panels[index].scale = Vector3(scale_factor,scale_factor,1.0)
		var marker_scale: float = 2.0*tan(deg_to_rad(30.0)) if group[4] else 1.0
		coverage_marker.position.y = 2.25*marker_scale
		coverage_marker.scale = Vector3(marker_scale,marker_scale,1.0)
		RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(group[5])
		attributes.dof_blur_near_enabled = false
		attributes.dof_blur_far_enabled = false
		await _settle()
		var sharp := _capture(label + "_off")
		var marker_center := Vector2i(camera.unproject_position(coverage_marker.global_position))
		var coverage_pixels := 0
		for y in range(marker_center.y-20,marker_center.y+20):
			for x in range(marker_center.x-22,marker_center.x+22):
				var color := sharp.get_pixel(x,y)
				if color.r > 0.24 and color.r < 0.96: coverage_pixels += 1
		_check(coverage_pixels == 0 if group[1] == Viewport.MSAA_DISABLED else coverage_pixels > 12,label + "_geometric_sample_coverage",coverage_pixels)
		var sharp_contrast := _contrasts(sharp)
		_check(sharp_contrast[0] > 0.45 and sharp_contrast[1] > 0.45 and sharp_contrast[2] > 0.45, label + "_sharp_contrast", sharp_contrast)
		var metadata: Dictionary = probe.metadata
		var samples_valid: bool = metadata["samples"] in [1,2,4,8] and metadata["samples"] <= (1 << int(group[1]))
		if RenderingServer.get_current_rendering_driver_name() == "webgpu": samples_valid = metadata["samples"] == (1 if group[1] == Viewport.MSAA_DISABLED else 4)
		_check(samples_valid and metadata["requested_msaa"] == group[1],label + "_effective_samples",metadata)
		_check(metadata["size"] == viewport.size, label + "_depth_extent", metadata)
		read_complete = false
		var positions := PackedInt32Array([0,0,0,0,0,0,0,0])
		for index in 3:
			var point := camera.unproject_position(panels[index].global_position)
			positions[index] = int(point.x)
			positions[index+4] = int(point.y)
		RenderingServer.call_on_render_thread(_read_depth.bind(metadata,positions))
		var deadline := Time.get_ticks_msec() + 10000
		while not read_complete and Time.get_ticks_msec() < deadline: await get_tree().process_frame
		for index in 3:
			var distance: float = [3.0,6.0,10.0][index]
			var expected_depth := (100.0-distance)/99.9 if not group[4] else (10.0/distance-0.1)/99.9
			var observed := readback[index] if readback.size() == 3 else -1.0
			_check(read_complete and is_finite(observed) and absf(observed-expected_depth) < 0.002, label + "_depth_" + str(index), [observed,expected_depth])
		attributes.dof_blur_near_enabled = true
		attributes.dof_blur_far_enabled = true
		await _settle()
		var blurred := _capture(label + "_on")
		var blur_contrast := _contrasts(blurred)
		_check(blur_contrast[0] < sharp_contrast[0]*0.65,label + "_near_blurred",blur_contrast)
		_check(blur_contrast[1] > sharp_contrast[1]*0.85,label + "_focus_preserved",blur_contrast)
		_check(blur_contrast[2] < sharp_contrast[2]*0.65,label + "_far_blurred",blur_contrast)
		attributes.dof_blur_near_enabled = false
		attributes.dof_blur_far_enabled = false
		await _settle()
		var recovered := _capture(label + "_reset")
		_check(recovered.get_data() == sharp.get_data(),label + "_reset_exact")
	var file := FileAccess.open(output_directory.path_join("manifest.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"captures":captures,"passed":passed,"failed":failed},"\t"))
	RenderingServer.call_on_render_thread(_cleanup)

func _contrasts(image: Image) -> Array[float]:
	var result: Array[float] = []
	for index in 3:
		var center := Vector2i(camera.unproject_position(panels[index].global_position))
		var sum := 0.0
		var squares := 0.0
		var count := 0
		for y in range(center.y-32,center.y+32):
			for x in range(center.x-16,center.x+16):
				var value := image.get_pixel(x,y).r
				sum += value
				squares += value*value
				count += 1
		result.append(sqrt(maxf(0.0,squares/count-pow(sum/count,2))))
	return result

func _setup_reader() -> void:
	rd = RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_depth;
layout(set=0,binding=1,std430) restrict writeonly buffer Output { float values[]; } output_data;
layout(push_constant,std430) uniform Params { ivec4 x; ivec4 y; } params;
void main(){for(int i=0;i<3;i++)output_data.values[i]=texelFetch(source_depth,ivec2(params.x[i],params.y[i]),0).r;}
"""
	for hardware_depth in [false,true]:
		if hardware_depth: source.source_compute = source.source_compute.replace("source_depth","godot_depth_source")
		var spirv := rd.shader_compile_spirv_from_source(source,false)
		if not spirv.compile_error_compute.is_empty(): push_error(spirv.compile_error_compute)
		var shader := rd.shader_create_from_spirv(spirv,"MSAA resolved depth probe")
		shaders.append(shader)
		pipelines.append(rd.compute_pipeline_create(shader))
	sampler = rd.sampler_create(RDSamplerState.new())

func _read_depth(metadata: Dictionary, positions: PackedInt32Array) -> void:
	var index := 1 if metadata["depth_attachment"] else 0
	var shader := shaders[index]
	var pipeline := pipelines[index]
	var output := rd.storage_buffer_create(12)
	var texture := RDUniform.new()
	texture.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	texture.binding = 0
	texture.add_id(sampler)
	texture.add_id(metadata["depth"])
	var buffer := RDUniform.new()
	buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer.binding = 1
	buffer.add_id(output)
	var uniform_set := rd.uniform_set_create([texture,buffer],shader,0)
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands,pipeline)
	rd.compute_list_bind_uniform_set(commands,uniform_set,0)
	rd.compute_list_set_push_constant(commands,positions.to_byte_array(),32)
	rd.compute_list_dispatch(commands,1,1,1)
	rd.compute_list_end()
	var data := rd.buffer_get_data(output)
	rd.free_rid(uniform_set)
	rd.free_rid(output)
	_read_done.call_deferred(data.to_float32_array())

func _read_done(values: PackedFloat32Array) -> void:
	readback = values
	read_complete = true

func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame
		var previous: int = probe.observed_frames
		RenderingServer.force_draw(false,1.0/60.0)
		RenderingServer.force_sync()
		var deadline := Time.get_ticks_msec()+5000
		while probe.observed_frames == previous and Time.get_ticks_msec() < deadline: await get_tree().process_frame
		if probe.observed_frames == previous: push_error("MSAA DOF compositor handoff timed out")

func _settle() -> void:
	var stable := 0
	var previous := -1
	var deadline := Time.get_ticks_msec()+60000
	while stable < 8 and Time.get_ticks_msec() < deadline:
		await _frames(1)
		var requests := 0
		for source: int in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS,RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE,RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]: requests += RenderingServer.get_rendering_info(source)
		stable = stable+1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 and requests == previous else 0
		previous = requests
	if stable < 8: push_error("MSAA DOF pipelines did not settle")
	await _frames(2)

func _capture(label: String) -> Image:
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBAF)
	_check(image.get_size() == viewport.size,label + "_extent")
	var finite := true
	for value: float in image.get_data().to_float32_array(): finite = finite and is_finite(value) and value >= 0.0 and value <= 1.01
	_check(finite,label + "_finite")
	var file := FileAccess.open(output_directory.path_join(label+".rgba32f"),FileAccess.WRITE)
	file.store_buffer(image.get_data())
	image.save_png(output_directory.path_join(label+".png"))
	captures.append({"label":label,"width":viewport.size.x,"height":viewport.size.y})
	return image

func _check(success: bool,label: String,detail: Variant = "") -> void:
	passed += int(success)
	failed += int(not success)
	print("MSAA_DOF %s %s %s" % ["PASS" if success else "FAIL",label,detail])

func _cleanup() -> void:
	for resource: RID in [sampler] + pipelines + shaders: rd.free_rid(resource)
	_finish.call_deferred()

func _finish() -> void:
	print("MSAA_DOF COMPLETE passed=%d failed=%d captures=%d" % [passed,failed,captures.size()])
	get_tree().quit(0 if failed == 0 and passed == 153 else 1)
