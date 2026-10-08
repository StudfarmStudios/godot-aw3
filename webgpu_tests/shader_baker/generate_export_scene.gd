extends SceneTree

var marker := 0
var expected: Array[String] = []

func material(label: String) -> ShaderMaterial:
	marker += 1
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(%f, 0.2, 0.1); }" % (float(marker) / 20.0)
	var result := ShaderMaterial.new()
	result.resource_name = label
	result.shader = shader
	expected.append(label)
	return result

func child(parent: Node, node: Node) -> void:
	parent.add_child(node)
	node.owner = parent

func _initialize() -> void:
	var scene := Node3D.new()
	scene.name = "ShaderBakerCoverage"
	scene.set_script(load("res://material_holder.gd"))
	var mesh := MeshInstance3D.new()
	mesh.name = "SurfaceOverrideOverlay"
	var box := BoxMesh.new()
	box.material = material("mesh_surface")
	mesh.mesh = box
	mesh.material_override = material("material_override")
	mesh.material_overlay = material("material_overlay")
	mesh.material_overlay.next_pass = material("next_pass")
	child(scene, mesh)
	var multi := MultiMeshInstance3D.new()
	multi.name = "MultiMeshMaterial"
	multi.multimesh = MultiMesh.new()
	var multi_box := BoxMesh.new()
	multi_box.material = material("multimesh_surface")
	multi.multimesh.mesh = multi_box
	child(scene, multi)
	var particles := GPUParticles3D.new()
	particles.name = "ParticleDrawMaterial"
	particles.emitting = false
	var particle_box := BoxMesh.new()
	particle_box.material = material("particle_surface")
	particles.draw_pass_1 = particle_box
	child(scene, particles)
	var nested: Resource = load("res://nested_materials.gd").new()
	nested.values = [{"array_dictionary": [material("nested_array_dictionary")], material("dictionary_key"): material("dictionary_value")}]
	scene.nested_resources = [nested]
	var standard := StandardMaterial3D.new()
	standard.resource_name = "standard_material"
	standard.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	standard.vertex_color_use_as_albedo = true
	expected.append(standard.resource_name)
	scene.nested_resources.append(standard)
	# Exercise sampler aliasing in serialized seed metadata, not only untextured shaders.
	var anisotropic := StandardMaterial3D.new()
	anisotropic.resource_name = "anisotropic_material"
	anisotropic.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	anisotropic.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var image := Image.create_empty(4, 4, true, Image.FORMAT_RGBA8)
	image.fill(Color(0.8, 0.2, 0.1))
	anisotropic.albedo_texture = ImageTexture.create_from_image(image)
	expected.append(anisotropic.resource_name)
	scene.nested_resources.append(anisotropic)
	var label := Label3D.new()
	label.name = "GeneratedLabel"
	label.text = "WebGPU"
	child(scene, label)
	var sprite := Sprite3D.new()
	sprite.name = "GeneratedSprite"
	child(scene, sprite)
	var packed := PackedScene.new()
	var error := packed.pack(scene)
	if error == OK:
		error = ResourceSaver.save(packed, "res://coverage.tscn")
	if error != OK:
		push_error("Coverage scene generation failed: %d" % error)
		quit(1)
		return
	var file := FileAccess.open("res://expected_materials.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(expected))
	scene.free()
	quit()
