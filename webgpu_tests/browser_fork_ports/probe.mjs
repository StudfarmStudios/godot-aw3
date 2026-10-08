#!/usr/bin/env node
// Exercise the actual installed browser, not a downloaded test-only build.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { mkdir, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
const args = Object.fromEntries(process.argv.slice(2).map(value => value.replace(/^--/, '').split('=')));
if (!args['node-modules']) throw new Error('Supply --node-modules=/path/to/package.json resolving puppeteer-core and pngjs');
const require = createRequire(resolve(args['node-modules']));
const puppeteer = require('puppeteer-core');
const output = resolve(args.output || '/private/tmp/aw3-browser-capabilities');
await mkdir(output, {recursive:true});
const server = createServer((request,response) => {
  response.writeHead(200, {'Content-Type':'text/html', 'Cross-Origin-Opener-Policy':'same-origin', 'Cross-Origin-Embedder-Policy':'require-corp'});
  response.end('<!doctype html><title>Godot WebGPU capability probe</title><canvas width="8" height="8"></canvas>');
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const records = [];
try {
  for (const name of (args.browser || 'chrome,firefox').split(',')) {
    const profile = await mkdtemp(join(tmpdir(),'aw3-'+name+'-probe-'));
    let browser;
    const record = {browser:name, platform:process.platform, forcedWebGPU:false};
    try {
      browser = await puppeteer.launch({browser:name, executablePath: name === 'firefox' ? (args['firefox-bin'] || '/Applications/Firefox.app/Contents/MacOS/firefox') : (args['chrome-bin'] || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'), headless:false,userDataDir:profile,defaultViewport:{width:640,height:480},timeout:60000,protocolTimeout:120000});
      record.version = await browser.version();
      const page = await browser.newPage();
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      record.capabilities = await page.evaluate(async() => {
        const get = async () => {
          const adapter = await navigator.gpu?.requestAdapter({powerPreference:'high-performance'});
          if (!adapter) return {webgpu:!!navigator.gpu,adapter:false};
          const info = adapter.info || await adapter.requestAdapterInfo?.();
          const device = await adapter.requestDevice();
          const result = {webgpu:true,adapter:true,info:info?Object.fromEntries(['vendor','architecture','device','description','isFallbackAdapter'].map(k=>[k,info[k]])):null,features:[...adapter.features],limits:Object.fromEntries(['maxSampledTexturesPerShaderStage','maxStorageBuffersPerShaderStage','maxStorageTexturesPerShaderStage','maxBindingsPerBindGroup','maxBindGroups'].map(k=>[k,adapter.limits[k]]))};
          device.destroy(); return result;
        };
        return {secureContext:isSecureContext,crossOriginIsolated,sharedArrayBuffer:typeof SharedArrayBuffer!=='undefined',offscreenCanvas:typeof OffscreenCanvas!=='undefined',userAgent:navigator.userAgent,...await get()};
      });
      record.passed = record.capabilities.adapter && record.capabilities.crossOriginIsolated;
    } catch(error) {record.passed=false;record.error=String(error.stack||error);}
    finally {if(browser) await browser.close().catch(()=>{});await rm(profile,{recursive:true,force:true});}
    records.push(record);console.log(JSON.stringify(record));
  }
} finally {await new Promise(resolve=>server.close(resolve));}
await writeFile(join(output,'result.json'),JSON.stringify(records,null,2)+'\n');
process.exit(records.every(record=>record.passed)?0:1);
