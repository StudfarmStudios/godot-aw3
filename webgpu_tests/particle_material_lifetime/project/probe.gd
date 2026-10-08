extends SceneTree

var material_refs: Array[WeakRef] = []

func _initialize() -> void:
	call_deferred("_run")

func _add_particles() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = 8
	var material := ParticleProcessMaterial.new()
	material.direction = Vector3(0, 1, 0)
	material.spread = 30.0
	material.initial_velocity_min = 2.0
	material.initial_velocity_max = 5.0
	material.damping_min = 0.5
	material.damping_max = 1.0
	material.scale_min = 0.1
	material.scale_max = 0.3
	material.color = Color(1.0, 0.5, 0.2)
	material.turbulence_enabled = true
	material.turbulence_noise_strength = 2.0
	material.turbulence_noise_speed = Vector3(0.5, 0.5, 0.5)
	particles.process_material = material
	particles.trail_enabled = true
	particles.trail_lifetime = 0.3
	particles.draw_pass_1 = QuadMesh.new()
	root.add_child(particles)
	material_refs.append(weakref(material))
	return particles

func _run() -> void:
	var nodes: Array[GPUParticles3D] = []
	for _i in range(4):
		nodes.append(_add_particles())
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, 3, 10)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	for _i in range(8):
		await process_frame
		# Repeated cache lookups must not register the same owner twice.
		for node in nodes:
			node.process_material.get_rid()
	var explicit_free := "runtime" in OS.get_cmdline_user_args()
	if explicit_free:
		for node in nodes:
			node.free()
		nodes.clear()
		for _i in range(2):
			await process_frame
	var live := 0
	for reference in material_refs:
		if reference.get_ref() != null:
			live += 1
	var expected_live := 0 if explicit_free else 4
	var passed := live == expected_live
	print("PARTICLE_LIFETIME_RESULT ", JSON.stringify({"pass": passed, "materials": 4, "live_before_shutdown": live, "case": "runtime" if explicit_free else "shutdown"}))
	if not passed:
		push_error("Particle material ownership did not match the teardown case")
	quit(0 if passed else 1)
