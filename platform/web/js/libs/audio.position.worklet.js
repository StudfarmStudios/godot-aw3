/**************************************************************************/
/*  godot.audio.position.worklet.js                                                      */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

/**
 * Number of render quanta between position messages on the fallback path.
 * A quantum is 128 frames, so a processor renders ~344 of them per second and
 * every playing sound has a processor of its own. The main thread only ever
 * samples the position once a frame, so posting every quantum was two orders
 * of magnitude more traffic than anyone could read.
 */
const MESSAGE_INTERVAL_QUANTA = 8;

class GodotPositionReportingProcessor extends AudioWorkletProcessor {
	static get parameterDescriptors() {
		return [
			{
				name: 'reset',
				defaultValue: 0,
				minValue: 0,
				maxValue: 1,
				automationRate: 'k-rate',
			},
		];
	}

	constructor(...args) {
		super(...args);
		this.position = 0;
		this.quantaSincePost = 0;

		// When the page can share memory, the position goes into a buffer the
		// main thread reads on demand and no messages are posted at all.
		const options = args[0] ?? {};
		const processorOptions = options['processorOptions'] ?? {};
		const positionBuffer = processorOptions['positionBuffer'] ?? null;
		/** @type {Int32Array?} */
		this.frames = positionBuffer != null ? new Int32Array(positionBuffer) : null;

		this.port.onmessage = (event) => {
			switch (event.data['type']) {
			case 'clear':
				this._setPosition(0);
				break;
			default:
				// Do nothing.
			}
		};
	}

	_setPosition(position) {
		this.position = position;
		if (this.frames != null) {
			Atomics.store(this.frames, 0, position);
		}
	}

	process(inputs, _outputs, parameters) {
		if (parameters['reset'][0] > 0) {
			this._setPosition(0);
		}

		if (inputs.length > 0) {
			const input = inputs[0];
			if (input.length > 0) {
				this._setPosition(this.position + input[0].length);
				this.quantaSincePost++;
				if (this.frames == null && this.quantaSincePost >= MESSAGE_INTERVAL_QUANTA) {
					this.quantaSincePost = 0;
					this.port.postMessage({ 'type': 'position', 'data': this.position });
				}
			}
		}

		return true;
	}
}

registerProcessor('godot-position-reporting-processor', GodotPositionReportingProcessor);
