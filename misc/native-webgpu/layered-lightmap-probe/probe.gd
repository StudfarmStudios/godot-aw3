extends Node3D

# Constant-color BC6H unsigned blocks, generated once and checked against Metal.
# Keep the fixture independent of the active driver's texture compressor.
const BC6_BLOCKS := [
	"0e000000000000000000000000000000",
	"ee1e0000000000000000000000000000",
	"0e807b00000000000000000000000000",
	"0e0000ee010000000000000000000000",
]
const BC1_BLOCKS := [
	"0000000000000000", "00f800f800000000", "e007e00700000000", "1f001f0000000000",
]
const COLORS := [Color.BLACK, Color.RED, Color.GREEN, Color.BLUE]
const SLICES := [0, 5, 43]

func _ready() -> void:
	var format_name := "bc6"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--format="):
			format_name = arg.trim_prefix("--format=")
	if format_name not in ["bc6", "bc1", "rgba8"]:
		push_error("LAYERED_LIGHTMAP_PROBE unknown format " + format_name)
		get_tree().quit(1)
		return
	Engine.max_fps = 60
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.size = 6.0
	camera.position.z = 4.0
	add_child(camera)
	var layers: Array[Image] = []
	for layer in 44:
		var color_index := SLICES.find(layer) + 1
		if format_name == "rgba8":
			var image := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
			image.fill(COLORS[color_index])
			layers.append(image)
		else:
			var block: PackedByteArray = (BC6_BLOCKS if format_name == "bc6" else BC1_BLOCKS)[color_index].hex_decode()
			var bytes := PackedByteArray()
			for index in 16 * 16:
				bytes.append_array(block)
			layers.append(Image.create_from_data(64, 64, false,
				Image.FORMAT_BPTC_RGBFU if format_name == "bc6" else Image.FORMAT_DXT1, bytes))
	var atlas := Texture2DArray.new()
	if atlas.create_from_images(layers) != OK:
		push_error("LAYERED_LIGHTMAP_PROBE texture creation failed")
		get_tree().quit(1)
		return
	var data := LightmapGIData.new()
	data.lightmap_textures = [atlas]
	for row in 2:
		for column in 3:
			var quad := QuadMesh.new()
			quad.size = Vector2(1.5, 1.5)
			quad.add_uv2 = true
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, quad.get_mesh_arrays(), [], {},
				Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES if row == 1 else 0)
			var material := StandardMaterial3D.new()
			material.albedo_color = Color.WHITE
			mesh.surface_set_material(0, material)
			var instance := MeshInstance3D.new()
			instance.name = "BakedMesh%d%d" % [row, column]
			instance.mesh = mesh
			instance.position = Vector3((column - 1) * 2.0, 1.0 - row * 2.0, 0)
			instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			add_child(instance)
			data.add_user(NodePath("../" + instance.name), Rect2(0, 0, 1, 1), SLICES[column], -1)
	var lightmap := LightmapGI.new()
	add_child(lightmap)
	lightmap.light_data = data
	for frame in 90:
		await get_tree().process_frame
	var quiet_frames := 0
	for frame in 1200:
		await get_tree().process_frame
		quiet_frames = quiet_frames + 1 if RenderingServer.get_pending_pipeline_compilation_count() == 0 else 0
		if quiet_frames >= 5:
			break
	if quiet_frames < 5:
		push_error("LAYERED_LIGHTMAP_PROBE pipeline compilation timeout")
		get_tree().quit(1)
		return
	var pixels: Array[Color] = []
	var passed := false
	# WebGPU readbacks complete asynchronously; wait for an actual rendered image.
	for attempt in 120:
		var image := get_viewport().get_texture().get_image()
		if image != null and not image.is_empty():
			pixels.clear()
			passed = true
			for row in 2:
				for column in 3:
					var point := camera.unproject_position(Vector3((column - 1) * 2.0, 1.0 - row * 2.0, 0))
					var pixel := image.get_pixelv(Vector2i(point))
					pixels.append(pixel)
					var expected: Color = COLORS[column + 1]
					passed = passed and absf(pixel.r - expected.r) < 0.1 and absf(pixel.g - expected.g) < 0.1 and absf(pixel.b - expected.b) < 0.1
			if passed:
				break
		await get_tree().process_frame
	print("LAYERED_LIGHTMAP_PROBE %s format=%s pixels=%s" % ["PASS" if passed else "FAIL", format_name, pixels])
	get_tree().quit(0 if passed else 1)
