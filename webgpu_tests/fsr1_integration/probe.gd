extends CompositorEffect

# Observe the buffers left by the previous frame's real built-in FSR passes.
# Only value metadata is sent to the main thread; RenderData is never retained.
var metadata: Dictionary = {}

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT

func _render_callback(_type: int, render_data: RenderData) -> void:
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var snapshot := {
		"internal_size": buffers.get_internal_size(),
		"target_size": buffers.get_target_size(),
		"scaling_mode": buffers.get_scaling_3d_mode(),
		"upscale": {},
		"rcas": {},
	}
	for entry: Array in [["upscale_texture", "upscale"], ["rcas_output", "rcas"]]:
		if buffers.has_texture("FSR", entry[0]):
			var format := buffers.get_texture_format("FSR", entry[0])
			snapshot[entry[1]] = {
				"format": format.format,
				"width": format.width,
				"height": format.height,
				"layers": format.array_layers,
				"usage": format.usage_bits,
				"rid": buffers.get_texture("FSR", entry[0]).get_id(),
			}
	_publish.call_deferred(snapshot)

func _publish(snapshot: Dictionary) -> void:
	metadata = snapshot
