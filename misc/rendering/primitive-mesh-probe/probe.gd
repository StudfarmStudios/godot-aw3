extends SceneTree

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("PRIMITIVE_MESH_PROBE_FAIL ", label)

func verify_geometry(mesh: PrimitiveMesh) -> void:
	# The first read must already contain geometry. Reading again can hide the
	# WebGPU regression by allowing the previous asynchronous readback to finish.
	var arrays := mesh.surface_get_arrays(0)
	var label := mesh.get_class()
	check(arrays.size() == Mesh.ARRAY_MAX, label + " array slots")
	if arrays.size() != Mesh.ARRAY_MAX:
		return
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var radius := 0.0
	for vertex in vertices:
		radius = maxf(radius, vertex.length())
	check(not vertices.is_empty() and radius > 0.1,
		label + " first read has nonzero vertices")
	var triangles := 0
	var valid_indices := true
	for index in indices:
		valid_indices = valid_indices and index >= 0 and index < vertices.size()
	check(valid_indices, label + " indices in range")
	if valid_indices:
		for i in range(0, indices.size(), 3):
			var a := vertices[indices[i]]
			var b := vertices[indices[i + 1]]
			var c := vertices[indices[i + 2]]
			if (b - a).cross(c - a).length_squared() > 0.0000001:
				triangles += 1
	check(triangles > 0, label + " first read has drawable triangles")
	print("PRIMITIVE_MESH_PROBE_GEOMETRY ", label, " radius=", radius, " triangles=", triangles)

	# Callers may replace array slots and edit packed elements without changing
	# the primitive or a later caller's snapshot.
	var saved_vertices := vertices.duplicate()
	if not vertices.is_empty():
		vertices[0] = Vector3(1000, 1000, 1000)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays.clear()
	var fresh := mesh.get_mesh_arrays()
	check(fresh.size() == Mesh.ARRAY_MAX, label + " caller cannot clear cached array")
	check(fresh[Mesh.ARRAY_VERTEX] == saved_vertices, label + " caller cannot change cached vertices")

func run() -> void:
	var cylinder := CylinderMesh.new()
	cylinder.radial_segments = 6
	cylinder.rings = 0
	var torus := TorusMesh.new()
	torus.rings = 6
	torus.ring_segments = 6
	for mesh in [cylinder, torus, BoxMesh.new(), SphereMesh.new(), CapsuleMesh.new(), PlaneMesh.new(), PrismMesh.new(), QuadMesh.new()]:
		verify_geometry(mesh)

	var before := cylinder.get_mesh_arrays()
	var before_vertices: PackedVector3Array = before[Mesh.ARRAY_VERTEX]
	cylinder.height = 7.0
	var after := cylinder.get_mesh_arrays()
	var after_vertices: PackedVector3Array = after[Mesh.ARRAY_VERTEX]
	var height := 0.0
	for vertex in after_vertices:
		height = maxf(height, absf(vertex.y))
	check(is_equal_approx(height, 3.5), "property change is visible on the first read")
	check(before_vertices == before[Mesh.ARRAY_VERTEX], "update preserves older snapshot")
	check(before_vertices != after_vertices, "update replaces cached vertices")

	var normals: PackedVector3Array = after[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = after[Mesh.ARRAY_INDEX]
	cylinder.flip_faces = true
	var flipped := cylinder.get_mesh_arrays()
	var flipped_normals: PackedVector3Array = flipped[Mesh.ARRAY_NORMAL]
	var flipped_indices: PackedInt32Array = flipped[Mesh.ARRAY_INDEX]
	check(flipped_normals[0].is_equal_approx(-normals[0]), "flipped normals are cached")
	check(flipped_indices[0] == indices[1] and flipped_indices[1] == indices[0], "flipped winding is cached")

	cylinder.add_uv2 = true
	var unwrapped := cylinder.get_mesh_arrays()
	var uv2: PackedVector2Array = unwrapped[Mesh.ARRAY_TEX_UV2]
	check(uv2.size() == after_vertices.size(), "generated UV2 is cached")
	if checks != 54:
		failures += 1
		printerr("PRIMITIVE_MESH_PROBE_FAIL incomplete run: expected 54 checks, got ", checks)
	print("PRIMITIVE_MESH_PROBE_DONE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
