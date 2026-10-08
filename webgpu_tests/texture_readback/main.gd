extends SceneTree

var passed := 0
var failed := 0

func _initialize() -> void:
	RenderingServer.call_on_render_thread(_run)

func _check(condition: bool, label: String, actual: PackedByteArray, expected: PackedByteArray) -> void:
	if condition:
		passed += 1
		print("TEXTURE_READBACK PASS ", label)
	else:
		failed += 1
		print("TEXTURE_READBACK FAIL %s actual_size=%d expected_size=%d actual=%s expected=%s" % [label, actual.size(), expected.size(), actual.slice(0, 24).hex_encode(), expected.slice(0, 24).hex_encode()])

func _run() -> void:
	var rd := RenderingServer.get_rendering_device()
	var owned: Array[RID] = []
	for entry: Array in [
		["rgba8", RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, 4, false],
		["r8-storage", RenderingDevice.DATA_FORMAT_R8_UNORM, 1, true],
		["rg16-storage", RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, 4, true],
		["bc3", RenderingDevice.DATA_FORMAT_BC3_UNORM_BLOCK, 16, false],
	]:
		var tf := RDTextureFormat.new()
		tf.format = entry[1]
		tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		tf.width = 8
		tf.height = 8
		tf.array_layers = 2
		tf.mipmaps = 4
		tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		if entry[3]:
			tf.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		var layers: Array[PackedByteArray] = []
		var slice_expected := PackedByteArray()
		for layer in 2:
			var data := PackedByteArray()
			for mip in 4:
				var width := maxi(1, 8 >> mip)
				var count: int = (maxi(1, width / 4) ** 2) if entry[0] == "bc3" else width * width
				var mip_bytes := PackedByteArray()
				mip_bytes.resize(count * entry[2])
				if entry[0] == "rg16-storage":
					for component in count * 2:
						mip_bytes.encode_half(component * 2, float(1 + layer + mip))
				else:
					mip_bytes.fill(31 + layer * 64 + mip * 8)
				data.append_array(mip_bytes)
				if layer == 1 and mip >= 1:
					slice_expected.append_array(mip_bytes)
			layers.append(data)
		var texture := rd.texture_create(tf, RDTextureView.new(), layers)
		owned.append(texture)
		for layer in 2:
			var actual := rd.texture_get_data(texture, layer)
			_check(actual == layers[layer], "%s layer%d full_mips" % [entry[0], layer], actual, layers[layer])
		var slice := rd.texture_create_shared_from_slice(RDTextureView.new(), texture, 1, 1, 3)
		owned.append(slice)
		var actual := rd.texture_get_data(slice, 0)
		_check(actual == slice_expected, entry[0] + " mip1_layer1_slice", actual, slice_expected)
		# Reuse the same staging entry after a fresh upload; never return cached old pixels.
		var changed := layers[0].duplicate()
		changed.reverse()
		if entry[0] == "rg16-storage":
			# Keep numeric half values valid and exactly representable.
			for component in changed.size() / 2:
				changed.encode_half(component * 2, 7.0)
		rd.texture_update(texture, 0, changed)
		actual = rd.texture_get_data(texture, 0)
		_check(actual == changed, entry[0] + " refreshed_read", actual, changed)
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.width = 8
	tf.height = 4
	tf.depth = 4
	tf.mipmaps = 4
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var volume := PackedByteArray()
	var volume_slice := PackedByteArray()
	for mip in 4:
		var w := maxi(1, 8 >> mip)
		var h := maxi(1, 4 >> mip)
		var d := maxi(1, 4 >> mip)
		for z in d:
			var plane := PackedByteArray()
			plane.resize(w * h * 4)
			plane.fill(13 + mip * 24 + z * 4)
			volume.append_array(plane)
			if mip >= 1:
				volume_slice.append_array(plane)
	var texture := rd.texture_create(tf, RDTextureView.new(), [volume])
	owned.append(texture)
	var actual := rd.texture_get_data(texture, 0)
	_check(actual == volume, "3D all_mips_depth_planes", actual, volume)
	var slice := rd.texture_create_shared_from_slice(RDTextureView.new(), texture, 0, 1, 3, RenderingDevice.TEXTURE_SLICE_3D)
	owned.append(slice)
	actual = rd.texture_get_data(slice, 0)
	_check(actual == volume_slice, "3D mip_slice", actual, volume_slice)
	owned.reverse()
	for rid: RID in owned:
		if rid.is_valid():
			rd.free_rid(rid)
	print("TEXTURE_READBACK COMPLETE passed=%d failed=%d" % [passed, failed])
	call_deferred("quit", 0 if failed == 0 else 1)
