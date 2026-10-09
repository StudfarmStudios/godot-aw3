extends XRInterfaceExtension

# Supply a real renderer target through the supported XR override API, without
# a headset. One view only: this tests FSR destination compatibility, not XR.
signal image_ready(image: Image)
signal target_ready

var target_size := Vector2i(111, 69)
var color_texture := RID()
var target_format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
var initialized := false

func _get_name() -> StringName:
	return &"FSR1 regression target"

func _get_capabilities() -> int:
	return XRInterface.XR_MONO

func _initialize() -> bool:
	initialized = true
	return true

func _is_initialized() -> bool:
	return initialized

func _uninitialize() -> void:
	initialized = false

func _get_view_count() -> int:
	return 1

func _get_render_target_size() -> Vector2:
	return target_size

func _get_camera_transform() -> Transform3D:
	return Transform3D(Basis(), Vector3(0.0, 0.0, 3.0))

func _get_transform_for_view(_view: int, camera_transform: Transform3D) -> Transform3D:
	return camera_transform * _get_camera_transform()

func _get_projection_for_view(_view: int, aspect: float, z_near: float, z_far: float) -> PackedFloat64Array:
	var projection := Projection.create_orthogonal_aspect(2.0, aspect, z_near, z_far)
	var values := PackedFloat64Array()
	for column: Vector4 in [projection.x, projection.y, projection.z, projection.w]:
		values.append_array([column.x, column.y, column.z, column.w])
	return values

func _pre_draw_viewport(_render_target: RID) -> bool:
	return color_texture.is_valid()

func _get_color_texture() -> RID:
	return color_texture

func configure_target(format: int, size: Vector2i) -> void:
	RenderingServer.call_on_render_thread(_configure_target.bind(format, size))

func _configure_target(format: int, size: Vector2i) -> void:
	var rd := RenderingServer.get_rendering_device()
	if color_texture.is_valid():
		rd.free_rid(color_texture)
	target_format = format
	target_size = size
	var texture_format := RDTextureFormat.new()
	texture_format.format = format
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	color_texture = rd.texture_create(texture_format, RDTextureView.new())
	target_ready.emit.call_deferred()

func read_image() -> void:
	RenderingServer.call_on_render_thread(_read_image)

func _read_image() -> void:
	var rd := RenderingServer.get_rendering_device()
	var image_format := Image.FORMAT_RGBAH if target_format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT else Image.FORMAT_RGBA8
	var bytes := rd.texture_get_data(color_texture, 0)
	var image := Image.create_from_data(target_size.x, target_size.y, false, image_format, bytes)
	image_ready.emit.call_deferred(image)

func release_target() -> void:
	RenderingServer.call_on_render_thread(_release_target)

func _release_target() -> void:
	if color_texture.is_valid():
		RenderingServer.get_rendering_device().free_rid(color_texture)
		color_texture = RID()
