extends SceneTree

const READS := {
	"texture": "texture(depth_texture, SCREEN_UV).r",
	"textureLod": "textureLod(depth_texture, SCREEN_UV, 0.0).r",
	"texelFetch": "texelFetch(depth_texture, ivec2(SCREEN_UV * vec2(textureSize(depth_texture, 0))), 0).r",
}

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(256, 256)
	root.position = Vector2i(-4096, -4096)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.0
	camera.near = 0.1
	camera.far = 30.0
	viewport.add_child(camera)
	camera.position.z = 6.0
	camera.current = true
	for pose in [Vector3(-1.2, 0, 0), Vector3(1.2, 0, -2)]:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.6, 1.6, 0.5)
		box.mesh = mesh
		viewport.add_child(box)
		box.position = pose
	var overlay := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(6, 6)
	overlay.mesh = quad
	viewport.add_child(overlay)
	overlay.position.z = 2.0
	var failed := 0
	var color_image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	color_image.fill(Color.WHITE)
	var color_texture := ImageTexture.create_from_image(color_image)
	for msaa in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]:
		viewport.msaa_3d = msaa
		for label in READS:
			var shader := Shader.new()
			shader.code = """shader_type spatial;
	render_mode unshaded, depth_draw_never, fog_disabled;
	uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
	uniform sampler2D color_texture : filter_nearest;
	void fragment() {
		float depth = %s;
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		float distance = -view.z / view.w;
		ALBEDO = depth <= 0.0 ? vec3(0.0) : (distance < 6.5 ? vec3(1, 0, 0) : vec3(0, 0, 1));
		ALBEDO *= texture(color_texture, SCREEN_UV).rgb;
		ALPHA = 1.0;
	}""" % READS[label]
			var material := ShaderMaterial.new()
			material.shader = shader
			material.set_shader_parameter("color_texture", color_texture)
			overlay.material_override = material
			for frame in range(6):
				await process_frame
				RenderingServer.force_draw()
			# WebGPU delivers texture readbacks on a later frame. Flush any previous
			# material's readback before checking this one.
			for flush in range(2):
				viewport.get_texture().get_image()
				for frame in range(3):
					await process_frame
					RenderingServer.force_draw(false)
			var image: Image
			for attempt in range(120):
				image = viewport.get_texture().get_image()
				if image != null and not image.is_empty():
					break
				await process_frame
				RenderingServer.force_draw(false)
			if image == null or image.is_empty():
				push_error("SCENE_DEPTH %s readback timed out" % label)
				quit(1)
				return
			var near_pixel := image.get_pixel(77, 128)
			var far_pixel := image.get_pixel(179, 128)
			var sky_pixel := image.get_pixel(13, 13)
			var passed := near_pixel.r > 0.8 and near_pixel.b < 0.1 \
				and far_pixel.b > 0.8 and far_pixel.r < 0.1 \
				and sky_pixel.r < 0.1 and sky_pixel.b < 0.1
			print("SCENE_DEPTH msaa=%s %s %s near=%s far=%s sky=%s" % [msaa,
				label, "PASS" if passed else "FAIL", near_pixel, far_pixel, sky_pixel])
			if not passed:
				failed += 1
	quit(0 if failed == 0 else 1)
