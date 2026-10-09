extends Node3D

func _ready() -> void:
	print("SHADER_CACHE_USER " + OS.get_user_data_dir())
	var camera := Camera3D.new()
	camera.position.z = 3.0
	add_child(camera)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(0.9, 0.2, 0.1); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	mesh.material_override = material
	add_child(mesh)
	for unused in range(8):
		await get_tree().process_frame
	if "--placeholders" in OS.get_cmdline_user_args():
		# TAA needs motion vectors and enables the Forward+ advanced group only
		# after existing shader versions have allocated its placeholder RIDs.
		print("SHADER_CACHE_ADVANCED_ENABLE")
		get_viewport().use_taa = true
		for unused in range(4):
			await get_tree().process_frame
	RenderingServer.force_draw(false)
	RenderingServer.force_sync()
	var pixels := get_viewport().get_texture().get_image()
	var center := pixels.get_pixel(pixels.get_width() / 2, pixels.get_height() / 2)
	if center.r < 0.5 or center.r < center.g * 1.5:
		push_error("SHADER_CACHE_RENDER_FAILED " + str(center))
		get_tree().quit(1)
		return
	print("SHADER_CACHE_COMPLETE")
	get_tree().quit()
