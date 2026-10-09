/**
 * Validate the exported Forward+ scene on the engine's actual WebGPU device.
 * Linux uses software Vulkan; this does not validate hardware drivers.
 *
 * Usage: node smoke_test.mjs [export-dir]
 * SMOKE_REPORT selects the JSON report path (default: smoke-result.json).
 * Completion means scene coverage finished; browser shutdown is not an engine-exit assertion.
 */

import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertForwardPlusLimits, launchOptions, requiredForwardPlusLimits } from './browser_config.mjs';

const PROJECT = dirname(fileURLToPath(import.meta.url));
const MIME_TYPES = {
    '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
    '.pck': 'application/octet-stream', '.png': 'image/png', '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon', '.json': 'application/json',
};

function startServer(dir) {
    return new Promise((accept, reject) => {
        const server = createServer((req, res) => {
            const url = req.url.split('?')[0];
            const filePath = join(dir, url === '/' ? 'index.html' : url);
            if (url === '/favicon.ico' && !existsSync(filePath)) {
                res.writeHead(204);
                res.end();
                return;
            }
            if (!existsSync(filePath) || statSync(filePath).isDirectory()) {
                res.writeHead(404);
                res.end('Not found');
                return;
            }
            res.writeHead(200, {
                'Content-Type': MIME_TYPES[extname(filePath)] || 'application/octet-stream',
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Embedder-Policy': 'require-corp',
            });
            res.end(readFileSync(filePath));
        });
        server.once('error', reject);
        server.listen(0, '127.0.0.1', () => {
            accept({ server, url: `http://127.0.0.1:${server.address().port}` });
        });
    });
}

// Playwright serializes this function into the page, so it has no module scope.
// Intercept only the engine's own requests; do not create a second GPU device.
function monitorWebGPU(requiredLimits) {
    if (typeof GPUCanvasContext !== 'undefined') {
        const configure = GPUCanvasContext.prototype.configure;
        GPUCanvasContext.prototype.configure = function (...args) {
            const result = configure.apply(this, args);
            console.log('[WebGPU canvas] ' + JSON.stringify({ width: this.canvas.width, height: this.canvas.height }));
            return result;
        };
    }
    const limitsOf = (object) => {
        const limits = {};
        for (const key in object.limits) {
            if (typeof object.limits[key] === 'number') limits[key] = object.limits[key];
        }
        for (const key of Object.keys(requiredLimits)) limits[key] = object.limits[key];
        return limits;
    };
    const check = (object, label) => {
        const failures = Object.entries(requiredLimits)
            .filter(([key, minimum]) => !Number.isFinite(object.limits[key]) || object.limits[key] < minimum)
            .map(([key, minimum]) => `${key}=${object.limits[key]} (requires ${minimum})`);
        if (failures.length) {
            const message = `${label} cannot run Forward+: ${failures.join(', ')}`;
            console.error('[WebGPU capability failure] ' + message);
            throw new Error(message);
        }
    };
    if (!navigator.gpu) {
        console.error('[WebGPU capability failure] navigator.gpu is unavailable');
        return;
    }
    const requestAdapter = navigator.gpu.requestAdapter.bind(navigator.gpu);
    navigator.gpu.requestAdapter = async (...args) => {
        const adapter = await requestAdapter(...args);
        if (!adapter) {
            console.error('[WebGPU capability failure] No adapter returned');
            return adapter;
        }
        const info = adapter.info;
        console.log('[WebGPU adapter] ' + JSON.stringify({
            vendor: info?.vendor, architecture: info?.architecture,
            device: info?.device, description: info?.description,
            isFallbackAdapter: adapter.isFallbackAdapter,
            features: Array.from(adapter.features), limits: limitsOf(adapter),
        }));
        check(adapter, 'adapter');
        const requestDevice = adapter.requestDevice.bind(adapter);
        adapter.requestDevice = async (...deviceArgs) => {
            console.log('[WebGPU request] ' + JSON.stringify(deviceArgs[0] || {}));
            const device = await requestDevice(...deviceArgs);
            console.log('[WebGPU device] ' + JSON.stringify({
                features: Array.from(device.features), limits: limitsOf(device),
            }));
            device.lost.then((info) => {
                console.error('[WebGPU device lost] ' + JSON.stringify({ reason: info.reason, message: info.message }));
            });
            device.addEventListener('uncapturederror', (event) => {
                console.error('[WebGPU uncaptured error] ' + (event.error?.message || String(event.error)));
            });
            check(device, 'device');
            return device;
        };
        return adapter;
    };
}

export async function runSmokeTest({
    exportDir = join(PROJECT, 'export'),
    reportPath = process.env.SMOKE_REPORT || 'smoke-result.json',
    platform = process.platform,
    viewport = platform === 'linux' ? { width: 320, height: 180 } : { width: 1280, height: 720 },
    timeoutMs = platform === 'linux' ? 300000 : 120000,
    pollIntervalMs = 1000,
    chromium = null,
    serve = startServer,
    logger = console,
    options = launchOptions(platform),
} = {}) {
    const report = {
        passed: false, exportDir: resolve(exportDir), browserVersion: null,
        launchOptions: options, requiredForwardPlusLimits, platform, viewport, timeoutMs,
        adapters: [], devices: [], deviceRequests: [], canvases: [], console: [], pageErrors: [],
        errors: [], shaderErrors: [], deviceLost: false, deviceLosses: [],
        capabilityFailure: false, mobileFallback: false,
        engineStarted: false, engineFinished: false, enginePassed: false, timedOut: false,
    };
    let server;
    let browser;
    const started = Date.now();
    const failure = (message) => {
        report.errors.push(message);
        logger.log('FAIL: ' + message);
    };
    try {
        if (!existsSync(join(exportDir, 'index.html'))) throw new Error(`Export not found at ${exportDir}`);
        const hosted = await serve(exportDir);
        server = hosted.server;
        logger.log(`Export directory: ${exportDir}\nServer: ${hosted.url}`);
        const launcher = chromium || (await import('playwright')).chromium;
        logger.log('Browser launch options: ' + JSON.stringify(options));
        browser = await launcher.launch(options);
        report.browserVersion = browser.version();
        logger.log('Browser version: ' + report.browserVersion);
        logger.log('Smoke workload: ' + JSON.stringify({ platform, viewport, timeoutMs }));
        const page = await browser.newPage({ viewport });
        page.on('console', (msg) => {
            const text = msg.text();
            report.console.push({ type: msg.type(), text });
            const isError = msg.type() === 'error'
                || /(^|\s)(ERROR:|WARNING:|SCRIPT ERROR:|SHADER ERROR:)|GPUValidationError|uncaptured error/i.test(text);
            if (isError || text.startsWith('[WebGPU ') || process.env.VERBOSE) logger.log(`[${msg.type()}] ${text}`);
            if (isError) report.errors.push(text);
            for (const [prefix, collection, label] of [
                ['[WebGPU adapter] ', report.adapters, 'adapter'],
                ['[WebGPU device] ', report.devices, 'device'],
                ['[WebGPU request] ', report.deviceRequests, 'request'],
            ]) {
                if (!text.startsWith(prefix)) continue;
                try {
                    const details = JSON.parse(text.slice(prefix.length));
                    collection.push(details);
                    if (label !== 'request') assertForwardPlusLimits(details.limits, label);
                } catch (error) {
                    report.capabilityFailure = true;
                    failure(`Invalid ${label} capabilities: ${error.message}`);
                }
            }
            if (text.startsWith('[WebGPU canvas] ')) {
                try {
                    report.canvases.push(JSON.parse(text.slice('[WebGPU canvas] '.length)));
                } catch (error) {
                    failure('Invalid canvas diagnostic: ' + error.message);
                }
            }
            if (text.startsWith('[WebGPU capability failure]')) report.capabilityFailure = true;
            if (/Defaulting to Mobile renderer| - Mobile - /i.test(text)) {
                report.mobileFallback = true;
                failure('Forward+ coverage was replaced by the Mobile renderer: ' + text);
            }
            if (text.includes('[SHADER]') || text.includes('Tint conversion') || text.includes('spirv error')) {
                report.shaderErrors.push(text);
                if (!isError) logger.log('[SHADER ERROR] ' + text);
            }
            if (/device lost/i.test(text)) {
                report.deviceLost = true;
                report.deviceLosses.push(text);
                if (!isError) failure(text);
            }
            if (text.includes('[ShaderCoverage] Starting')) report.engineStarted = true;
            if (text.includes('[ShaderCoverage] PASS')) {
                report.engineFinished = true;
                report.enginePassed = true;
            }
            if (text.includes('[ShaderCoverage] FAIL')) {
                report.engineFinished = true;
                failure(text);
            }
        });
        page.on('pageerror', (error) => {
            const details = error.stack || error.message;
            report.pageErrors.push(details);
            failure('PAGE ERROR: ' + details);
        });
        await page.addInitScript(monitorWebGPU, requiredForwardPlusLimits);
        await page.goto(hosted.url, { waitUntil: 'domcontentloaded', timeout: Math.min(timeoutMs, 30000) });
        const deadline = Date.now() + timeoutMs;
        while (!report.engineFinished && !report.capabilityFailure && !report.mobileFallback && !report.deviceLost
            && Date.now() < deadline) {
            await new Promise((accept) => setTimeout(accept, Math.min(pollIntervalMs, Math.max(1, deadline - Date.now()))));
        }
        report.timedOut = !report.engineFinished && !report.capabilityFailure && !report.mobileFallback && !report.deviceLost;
    } catch (error) {
        failure(error.stack || error.message || String(error));
    } finally {
        try {
            if (browser) await browser.close();
        } catch (error) {
            failure('Browser cleanup failed: ' + error.message);
        }
        try {
            if (server) {
                server.closeAllConnections?.();
                await new Promise((accept, reject) => server.close((error) => error ? reject(error) : accept()));
            }
        } catch (error) {
            failure('Server cleanup failed: ' + error.message);
        }
    }
    if (!report.adapters.length) failure('No engine WebGPU adapter capabilities were observed');
    if (!report.devices.length) failure('No engine WebGPU device capabilities were observed');
    if (!report.engineStarted) failure('Engine never started');
    if (!report.engineFinished) failure(report.timedOut ? 'Engine did not complete within timeout' : 'Engine did not complete');
    if (report.engineFinished && !report.enginePassed) failure('Engine did not report a successful result');
    report.passed = report.errors.length === 0 && report.shaderErrors.length === 0 && !report.deviceLost
        && !report.capabilityFailure && !report.mobileFallback && report.engineStarted && report.engineFinished && report.enginePassed;
    report.seconds = (Date.now() - started) / 1000;
    mkdirSync(dirname(resolve(reportPath)), { recursive: true });
    writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
    logger.log(`${report.passed ? 'PASS' : 'FAIL'}: Forward+ scene coverage; ${report.errors.length} errors, `
        + `${report.shaderErrors.length} shader errors, device lost=${report.deviceLost}. Report: ${resolve(reportPath)}`);
    return report;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    runSmokeTest({ exportDir: process.argv[2] || join(PROJECT, 'export') }).then((report) => {
        process.exitCode = report.passed ? 0 : 1;
    }).catch((error) => {
        console.error('Fatal:', error);
        process.exitCode = 1;
    });
}
