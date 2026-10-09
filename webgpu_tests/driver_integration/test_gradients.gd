extends SceneTree

# get_image() must work with the headless renderer and reflect parameters before
# the deferred GPU update runs. No GPU readback is needed for procedural pixels.
func _initialize() -> void:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 0, 0, 1))
	gradient.set_color(1, Color(0, 0, 1, 1))
	var one := GradientTexture1D.new()
	one.gradient = gradient
	one.width = 1
	assert(one.get_image().get_pixel(0, 0).is_equal_approx(Color(1, 0, 0, 1)))
	one.use_hdr = true
	assert(one.get_image().get_pixel(0, 0).is_equal_approx(Color(1, 0, 0, 1)))
	one.width = 3
	assert(one.get_image().get_pixel(1, 0).is_equal_approx(Color(0.5, 0, 0.5, 1)))
	gradient.set_color(0, Color(4, 0, 0, 1))
	assert(one.get_image().get_pixel(0, 0).is_equal_approx(Color(4, 0, 0, 1)))
	var two := GradientTexture2D.new()
	two.gradient = gradient
	two.width = 3
	two.height = 3
	two.fill_from = Vector2.ZERO
	two.fill_to = Vector2(1, 0)
	two.use_hdr = true
	var hdr := two.get_image()
	assert(hdr.get_pixel(0, 1).is_equal_approx(Color(4, 0, 0, 1)))
	assert(hdr.get_pixel(1, 1).is_equal_approx(Color(2, 0, 0.5, 1)))
	assert(hdr.get_pixel(2, 1).is_equal_approx(Color(0, 0, 1, 1)))
	two.use_hdr = false
	assert(two.get_image().get_pixel(0, 1).is_equal_approx(Color(1, 0, 0, 1)))
	print("GRADIENT_TEST PASS width-one, HDR, LDR, immediate changes, 1D and 2D")
	quit(0)
