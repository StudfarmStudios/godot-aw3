extends Node

var finished_count := 0
var started_count := 0
var voices: Array[AudioStreamPlayer] = []
var sample: AudioStreamWAV

func _ready() -> void:
	sample = AudioStreamWAV.new()
	sample.format = AudioStreamWAV.FORMAT_16_BITS
	sample.mix_rate = 22050
	var data := PackedByteArray()
	data.resize(882) # Twenty milliseconds of silence.
	sample.data = data
	for i in range(32):
		voices.append(_make_voice())
	print("SAMPLE_COMPLETION_PROBE started")
	for frame in range(600):
		for i in range(voices.size()):
			var voice := voices[i]
			if (frame + i) % 3 == 0:
				voice.stop()
			elif (frame + i) % 7 == 0:
				voice.queue_free()
				voices[i] = _make_voice()
			else:
				voice.play()
				started_count += 1
			# Allow browser-thread completions to overlap application-worker
			# playback mutations, including destruction before a callback arrives.
			OS.delay_usec(100)
		await get_tree().process_frame
	for voice in voices:
		voice.stop()
		voice.play()
		started_count += 1
	await get_tree().create_timer(1.0).timeout
	var still_playing := 0
	for voice in voices:
		if voice.playing:
			still_playing += 1
	if finished_count == 0 or still_playing != 0:
		push_error("SAMPLE_COMPLETION_PROBE failed: finished=%d active=%d" % [finished_count, still_playing])
		return
	print("SAMPLE_COMPLETION_PROBE passed: started=%d finished=%d" % [started_count, finished_count])

func _make_voice() -> AudioStreamPlayer:
	var voice := AudioStreamPlayer.new()
	voice.stream = sample
	voice.playback_type = AudioServer.PLAYBACK_TYPE_SAMPLE
	voice.max_polyphony = 4
	voice.finished.connect(func(): finished_count += 1)
	add_child(voice)
	return voice
