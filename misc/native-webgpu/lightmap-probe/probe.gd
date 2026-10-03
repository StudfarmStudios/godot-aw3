extends Node3D

func _ready() -> void:
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.0
	camera.position.z = 3.0
	add_child(camera)
	# UV2 selects the synthetic baked atlas; there are no direct lights.
	var mesh := QuadMesh.new()
	mesh.size = Vector2(3, 3)
	mesh.add_uv2 = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.roughness = 1.0
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = "BakedMesh"
	instance.mesh = mesh
	instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	add_child(instance)
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 0, 0, 1))
	var atlas := Texture2DArray.new()
	atlas.create_from_images([image])
	var data := LightmapGIData.new()
	data.lightmap_textures = [atlas]
	data.add_user(NodePath("../BakedMesh"), Rect2(0, 0, 1, 1), 0, -1)
	var lightmap := LightmapGI.new()
	add_child(lightmap)
	lightmap.light_data = data
	for frame in range(90):
		await get_tree().process_frame
	# Check the final pipelines, and let native Dawn finish its async work before
	# device teardown. A visible fallback pixel alone is not sufficient.
	var quiet_frames := 0
	for frame in range(1200):
		await get_tree().process_frame
		if RenderingServer.get_pending_pipeline_compilation_count() == 0:
			quiet_frames += 1
			if quiet_frames >= 3:
				break
		else:
			quiet_frames = 0
	if quiet_frames < 3:
		push_error("LIGHTMAP_PROBE pipeline compilation timeout")
		get_tree().quit(1)
		return
	# Browser WebGPU returns texture readbacks asynchronously.
	var result: Image
	var pixel := Color.BLACK
	var passed := false
	for attempt in range(120):
		result = get_viewport().get_texture().get_image()
		if result != null and not result.is_empty():
			pixel = result.get_pixel(result.get_width() >> 1, result.get_height() >> 1)
			passed = pixel.r > 0.5 and pixel.g < 0.1 and pixel.b < 0.1
			if passed:
				break
		await get_tree().process_frame
	if result == null or result.is_empty():
		push_error("LIGHTMAP_PROBE readback timeout")
		get_tree().quit(1)
		return
	print("LIGHTMAP_PROBE %s pixel=%s" % ["PASS" if passed else "FAIL", pixel])
	get_tree().quit(0 if passed else 1)
