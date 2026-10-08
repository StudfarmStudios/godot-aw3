extends CompositorEffect
var metadata: Dictionary = {}
var observed_frames := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_depth = true

func _render_callback(_type: int, data: RenderData) -> void:
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null: return
	var depth := buffers.get_depth_layer(0)
	var format := RenderingServer.get_rendering_device().texture_get_format(depth)
	var snapshot := {"size":buffers.get_internal_size(), "samples":1 << buffers.get_texture_samples(), "requested_msaa":buffers.get_msaa_3d(), "depth":depth,"depth_format":format.format,"depth_attachment":bool(format.usage_bits & RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)}
	_publish.call_deferred(snapshot)

func _publish(value: Dictionary) -> void:
	metadata = value
	observed_frames += 1
