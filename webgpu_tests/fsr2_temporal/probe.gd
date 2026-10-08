extends CompositorEffect
var metadata: Dictionary = {}
var observed_frames := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT

func _render_callback(_type: int, data: RenderData) -> void:
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	_publish.call_deferred({"internal_size": buffers.get_internal_size(), "target_size": buffers.get_target_size(), "mode": buffers.get_scaling_3d_mode()})

func _publish(value: Dictionary) -> void:
	metadata = value
	observed_frames += 1
