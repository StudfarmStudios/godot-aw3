# WebAudio sample completion regression

Export this project with a threaded Web template built with
`proxy_to_pthread=yes`, and serve the export with cross-origin isolation headers.
Run it in real Chrome with audio autoplay enabled (or interact with the page to
resume its AudioContext).

The probe runs 600 frames of short sample playback, explicit stops, restarts,
and player destruction. Small application-thread delays allow natural
WebAudio completions on the browser thread to overlap those operations. It
then lets every remaining player finish naturally and verifies that none is
still playing and that finished signals were delivered.

Success is `SAMPLE_COMPLETION_PROBE passed` in the browser console, with no
engine errors. Before the completion callback was deferred to the application
thread, this reproduced `Parameter p_playback is null` in
`AudioServer::stop_sample_playback` in the application-worker build. Other
symptoms of the same unsynchronized cleanup include a null playback passed to
`AudioServer::stop_playback_stream`.

The exported template should also be tested without `proxy_to_pthread` to
exercise the direct callback path. All generated audio is silence.
