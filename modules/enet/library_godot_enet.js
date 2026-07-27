/**************************************************************************/
/*  library_godot_enet.js                                                 */
/**************************************************************************/
/* Web transport for ENet: carries the datagrams of an ENet client host   */
/* over a WebRTC data channel, negotiated against the game server's       */
/* webrtc-bridge through the signaling relay (see the AW3 server repo).   */
/*                                                                        */
/* The page (or C# via JavaScriptBridge.Eval) must configure the          */
/* endpoint before the engine creates the ENet client:                    */
/*                                                                        */
/*   GodotENetBridge.configure(signalingUrl, room, iceServers?)           */
/*                                                                        */
/* One socket = one signaling session = one peer connection with a single */
/* pre-negotiated unreliable/unordered data channel (id 0) — a faithful   */
/* UDP stand-in. The browser is always a client; hosting is unsupported.  */
/**************************************************************************/

const GodotENet = {
	$GodotENet__deps: ['$IDHandler', '$GodotRuntime'],
	$GodotENet__postset: 'GodotENet.expose();',
	$GodotENet: {
		config: null,

		expose: function () {
			// Escapes the emscripten module closure so the embedding page and
			// C# (JavaScriptBridge.Eval) can hand us the match endpoint.
			globalThis.GodotENetBridge = {
				configure: function (url, room, iceServers) {
					GodotENet.config = {
						'url': url,
						'room': room,
						'iceServers': iceServers || [],
					};
				},
			};
		},

		create: function (onDatagram) {
			const sock = {
				ws: null,
				pc: null,
				dc: null,
				dead: false,
				onDatagram: onDatagram,
			};
			const id = IDHandler.add(sock);
			const cfg = GodotENet.config;
			if (!cfg) {
				GodotRuntime.error('GodotENet: no endpoint configured — call GodotENetBridge.configure(url, room) before connecting. Packets will be dropped.');
				return id;
			}

			const send = function (msg) {
				if (sock.ws && sock.ws.readyState === WebSocket.OPEN) {
					sock.ws.send(JSON.stringify(msg));
				}
			};

			const ws = new WebSocket(`${cfg.url}?room=${encodeURIComponent(cfg.room)}&role=client`);
			sock.ws = ws;
			ws.onclose = function () {
				sock.dead = true;
			};
			ws.onerror = function () {
				GodotRuntime.error('GodotENet: signaling socket failed');
				sock.dead = true;
			};
			ws.onmessage = function (event) {
				let msg = null;
				try {
					msg = JSON.parse(event.data);
				} catch (e) {
					return;
				}
				switch (msg['type']) {
				case 'offer': {
					const pc = new RTCPeerConnection({ 'iceServers': cfg.iceServers });
					sock.pc = pc;
					// Must exist before the answer so its m-line is accepted;
					// parameters mirror the bridge exactly.
					const dc = pc.createDataChannel('enet', {
						'negotiated': true,
						'id': 0,
						'ordered': false,
						'maxRetransmits': 0,
					});
					dc.binaryType = 'arraybuffer';
					dc.onmessage = function (ev) {
						if (!(ev.data instanceof ArrayBuffer)) {
							return;
						}
						const buf = new Uint8Array(ev.data);
						const ptr = GodotRuntime.malloc(buf.length);
						HEAPU8.set(buf, ptr);
						sock.onDatagram(ptr, buf.length);
						GodotRuntime.free(ptr);
					};
					sock.dc = dc;
					pc.onicecandidate = function (ev) {
						if (!ev.candidate) {
							return;
						}
						send({
							'type': 'candidate',
							'data': {
								'media': ev.candidate.sdpMid || '',
								'index': ev.candidate.sdpMLineIndex || 0,
								'name': ev.candidate.candidate,
							},
						});
					};
					pc.setRemoteDescription({ 'type': 'offer', 'sdp': msg['data']['sdp'] }).then(function () {
						return pc.createAnswer();
					}).then(function (answer) {
						return pc.setLocalDescription(answer).then(function () {
							send({ 'type': 'answer', 'data': { 'sdp': pc.localDescription.sdp } });
						});
					}).catch(function (err) {
						GodotRuntime.error(`GodotENet: negotiation failed: ${err}`);
						sock.dead = true;
					});
					break;
				}
				case 'candidate':
					if (sock.pc) {
						sock.pc.addIceCandidate({
							'candidate': msg['data']['name'],
							'sdpMid': msg['data']['media'],
							'sdpMLineIndex': msg['data']['index'],
						}).catch(function (err) {
							GodotRuntime.error(`GodotENet: addIceCandidate: ${err}`);
						});
					}
					break;
				case 'error':
					GodotRuntime.error(`GodotENet: signaling error: ${event.data}`);
					sock.dead = true;
					break;
				default:
					// 'hello' (our peer id) needs no action: the relay tags our
					// messages and the data path has no peer ids.
					break;
				}
			};
			return id;
		},

		send: function (p_id, p_ptr, p_len) {
			const sock = IDHandler.get(p_id);
			if (!sock || !sock.dc || sock.dc.readyState !== 'open') {
				// Dropped like a UDP packet on an unroutable network; ENet's
				// own retransmission covers connection setup.
				return -1;
			}
			// Copy out of the wasm heap: the datagram must not alias memory
			// that may move on growth.
			sock.dc.send(HEAPU8.slice(p_ptr, p_ptr + p_len));
			return 0;
		},

		destroy: function (p_id) {
			const sock = IDHandler.get(p_id);
			if (!sock) {
				return;
			}
			sock.dead = true;
			if (sock.dc) {
				sock.dc.onmessage = null;
				sock.dc.close();
			}
			if (sock.pc) {
				sock.pc.close();
			}
			if (sock.ws) {
				sock.ws.onmessage = null;
				sock.ws.onclose = null;
				sock.ws.onerror = null;
				sock.ws.close();
			}
			IDHandler.remove(p_id);
		},
	},

	godot_js_enet_socket_create__proxy: 'sync',
	godot_js_enet_socket_create__sig: 'iii',
	godot_js_enet_socket_create: function (p_obj, p_on_datagram) {
		const cb = GodotRuntime.get_func(p_on_datagram).bind(null, p_obj);
		return GodotENet.create(cb);
	},

	godot_js_enet_socket_send__proxy: 'sync',
	godot_js_enet_socket_send__sig: 'iiii',
	godot_js_enet_socket_send: function (p_id, p_ptr, p_len) {
		return GodotENet.send(p_id, p_ptr, p_len);
	},

	godot_js_enet_socket_destroy__proxy: 'sync',
	godot_js_enet_socket_destroy__sig: 'vi',
	godot_js_enet_socket_destroy: function (p_id) {
		GodotENet.destroy(p_id);
	},
};

autoAddDeps(GodotENet, '$GodotENet');
mergeInto(LibraryManager.library, GodotENet);
