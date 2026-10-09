extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(0, 1.5, 4)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.5, 0.2)
	material.metallic = 0.3
	material.roughness = 0.35
	mesh.material_override = material
	stage.add_child(mesh)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	stage.add_child(light)
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.1, 0.2, 0.3)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.3, 0.3, 0.3)
	world_environment.environment = environment
	stage.add_child(world_environment)
	var probe := ReflectionProbe.new()
	probe.size = Vector3(8, 8, 8)
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	stage.add_child(probe)
	for frame in range(24):
		await RenderingServer.frame_post_draw
	print("ATLAS_ONCE_RENDERED")
	if not "--once-only" in OS.get_cmdline_user_args():
		probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
		for frame in range(8):
			await RenderingServer.frame_post_draw
		print("ATLAS_REALTIME_RENDERED")
	var image := root.get_texture().get_image()
	assert(image.get_width() == 160 and image.get_height() == 120)
	image.save_png("user://atlas-lifecycle.png")
	stage.queue_free()
	for frame in range(3):
		await RenderingServer.frame_post_draw
	print("ATLAS_LIFECYCLE_COMPLETE")
	quit(0)
