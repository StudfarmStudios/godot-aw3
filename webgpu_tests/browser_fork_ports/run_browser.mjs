#!/usr/bin/env node
// Real installed browsers, isolated profiles, hardware WebGPU, candidate exports.
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir,mkdtemp,rm,stat} from 'node:fs/promises';
import {resolve,join,extname,sep} from 'node:path';
import {tmpdir} from 'node:os';
import {verifyImages,verifyRebindImage} from './image_checks.mjs';
const args=Object.fromEntries(process.argv.slice(2).map(value=>value.replace(/^--/,'').split('=')));
if(!args.export||!args.output) throw new Error('Use --export=/path/export --output=/path/results [--browser=chrome,firefox]');
const root=resolve(args.export),output=resolve(args.output);
if (!args['node-modules']) throw new Error('Supply --node-modules=/path/to/package.json resolving puppeteer-core and pngjs');
const require=createRequire(resolve(args['node-modules']));
const puppeteer=require('puppeteer-core'),{PNG}=require('pngjs');
const exported=JSON.parse(await readFile(resolve(root,'../export-result.json'),'utf8'));
const timeout=Number(args.timeout||240000);
const noFloat32Filterable='no-float32-filterable' in args;
await mkdir(output,{recursive:true});
const mime={'.html':'text/html','.js':'text/javascript','.wasm':'application/wasm','.json':'application/json','.png':'image/png'};
const server=createServer(async(request,response)=>{
  try{
    const pathname=decodeURIComponent(new URL(request.url,'http://localhost').pathname);
    if(pathname==='/favicon.ico'){response.writeHead(204);response.end();return;}
    const path=resolve(root,'.'+(pathname==='/'?'/index.html':pathname));
    if(!path.startsWith(root+sep)) throw new Error('Outside export directory');
    let contents=await readFile(path);
    if(extname(path)==='.html') contents=Buffer.from(contents.toString().replace(/const GODOT_CONFIG = (\{[^\n]+\});/,(_,json)=>{const config=JSON.parse(json);config.args=['--verbose',...(noFloat32Filterable?['--','--webgpu-no-float32-filterable']:[])];return 'const GODOT_CONFIG = '+JSON.stringify(config)+'; GODOT_CONFIG.onExit=(code)=>{globalThis.__godotExit=code;};';}));
    response.writeHead(200,{'Content-Type':mime[extname(path)]||'application/octet-stream','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cache-Control':'no-store'});
    response.end(contents);
  }catch(error){response.writeHead(404);response.end('Not found');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const url=`http://127.0.0.1:${server.address().port}/index.html`;
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function closeOwned(browser){
  const process=browser.process();const streams=()=>{for(const stream of process?.stdio||[])stream?.destroy?.();};
  process?.once('exit',streams);if(process?.exitCode!==null)streams();
  let timer;try{await Promise.race([browser.close().catch(()=>{}),new Promise(resolve=>{timer=setTimeout(resolve,10000);})]);if(process?.exitCode===null&&process?.signalCode===null)process.kill('SIGKILL');}finally{clearTimeout(timer);}
}
async function idbSummary(page){return page.evaluate(async()=>{
  const db=await new Promise((resolve,reject)=>{const q=indexedDB.open('/userfs');q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  try{
    if(!db.objectStoreNames.contains('FILE_DATA'))return [];
    const data=await new Promise((resolve,reject)=>{const q=db.transaction('FILE_DATA','readonly').objectStore('FILE_DATA').openCursor();const values=[];q.onsuccess=async()=>{const cursor=q.result;if(!cursor){resolve(values);return;}const key=String(cursor.key),contents=cursor.value?.contents;if(contents&&key.includes('wgsl_cache/')&&key.endsWith('.bin')){const bytes=ArrayBuffer.isView(contents)?new Uint8Array(contents.buffer,contents.byteOffset,contents.byteLength):new Uint8Array(contents);values.push({key,bytes:bytes.length,header:Array.from(bytes.slice(0,40))});}cursor.continue();};q.onerror=()=>reject(q.error);});return data;
  }finally{db.close();}
});}
const records=[];
try{
  for(const name of (args.browser||'chrome,firefox').split(',')){
    const profile=await mkdtemp(join(tmpdir(),'aw3-'+name+'-ports-'));let browser;
    const record={browser:name,host:process.platform,threads:exported.threads,templateSha256:exported.template_sha256,engineSha256:exported.engine_sha256,forcedWebGPU:false,noFloat32Filterable,runs:[]};
    try{
      browser=await puppeteer.launch({browser:name,executablePath:name==='firefox'?(args['firefox-bin']||'/Applications/Firefox.app/Contents/MacOS/firefox'):(args['chrome-bin']||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),userDataDir:profile,headless:false,defaultViewport:{width:512,height:384,deviceScaleFactor:1},timeout:60000,protocolTimeout:timeout});
      record.version=await browser.version();
      for(const temperature of ['cold','warm']){
        const page=await browser.newPage();const run={temperature,console:[],errors:[],warnings:[],workers:[],phases:[]};record.runs.push(run);
        let warningContinuation=false;
        page.on('console',message=>{const text=message.text();run.console.push(text);const warning=/^WARNING:/.test(text)||(warningContinuation&&/^\s+at:/.test(text));warningContinuation=warning;if(warning)run.warnings.push(text);if((message.type()==='error'&&!warning)||/(^|\s)(ERROR:|SCRIPT ERROR:|SHADER ERROR:)|GPUValidationError|uncaptured error|device lost|BROWSER_WRONG|BROWSER_PIPELINES|Tint.*fail|SPIR-V.*fail/i.test(text))run.errors.push(text);});
        page.on('pageerror',error=>run.errors.push(String(error.stack||error)));
        page.on('workercreated',worker=>run.workers.push(worker.url()));
        await page.goto(url,{waitUntil:'domcontentloaded',timeout});
        run.capabilities=await page.evaluate(()=>({crossOriginIsolated,sharedArrayBuffer:typeof SharedArrayBuffer!=='undefined',offscreenCanvas:typeof OffscreenCanvas!=='undefined',userAgent:navigator.userAgent,webgpu:!!navigator.gpu}));
        const rebindDeadline=Date.now()+timeout;while(!run.console.some(text=>text.includes('BROWSER_REBIND_READY'))){if(run.errors.length)throw new Error(run.errors.join('\n'));if(Date.now()>rebindDeadline)throw new Error('Timed out waiting for rebind lifetime oracle');await sleep(100);}
        const rebindCanvas=await page.$('canvas');if(!rebindCanvas)throw new Error('No canvas');
        const rebindPixels=await rebindCanvas.screenshot({path:join(output,`${name}-${temperature}-rebind.png`)});
        run.rebindChecks=verifyRebindImage(PNG.sync.read(Buffer.from(rebindPixels)));
        await rebindCanvas.click({offset:{x:5,y:5}});await page.keyboard.press(' ');
        const images={};
        for(const phase of ['font','canvas_sdf','ssr_off','ssr_on','dof_off','dof_on']){
          const deadline=Date.now()+timeout;while(!run.console.some(text=>text.includes('BROWSER_READY '+phase))){if(run.errors.length)throw new Error(run.errors.join('\n'));if(Date.now()>deadline)throw new Error('Timed out waiting for '+phase);await sleep(100);}
          const canvas=await page.$('canvas');if(!canvas)throw new Error('No canvas');
          const path=join(output,`${name}-${temperature}-${phase}.png`);const bytes=await canvas.screenshot({path});images[phase]=PNG.sync.read(Buffer.from(bytes));run.phases.push(phase);
          await canvas.click({offset:{x:5,y:5}});await page.keyboard.press(' ');
        }
        const deadline=Date.now()+30000;while(!run.console.some(text=>text.includes('BROWSER_DONE'))&&Date.now()<deadline)await sleep(100);
        run.checks=[...run.rebindChecks,...verifyImages(images)];
        const rebindMessage=run.console.map(text=>text.match(/BROWSER_REBIND_RESULT (\{.*\})/)).find(Boolean);
        run.rebindResult=rebindMessage?JSON.parse(rebindMessage[1]):null;
        run.checks.push({name:'rebind_lifetime_resource_cleanup',passed:run.rebindResult?.passed===true&&['created','retired','dispatches','cells'].every(key=>run.rebindResult[key]===64)});
        const identity=run.console.map(text=>text.match(/\[WGSLCACHE\] translator\/profile ([a-f0-9]{64})/)).find(Boolean)?.[1];
        run.identity=identity;run.cacheMessages=run.console.filter(text=>text.includes('[WGSLCACHE]'));
        for(let i=0;i<30;i++){run.persisted=await idbSummary(page);if(run.persisted.length)break;await sleep(250);}
        run.checks.push({name:'explicit_forward_plus_webgpu',passed:run.console.some(text=>text.includes('BROWSER_DRIVER webgpu method=forward_plus'))});
        if(noFloat32Filterable)run.checks.push({name:'float32_filtering_omitted',passed:run.console.some(text=>text.includes('float32-filterable feature NOT available'))});
        run.checks.push({name:'wgsl_runtime_identity',passed:!!identity&&(!exported.wgsl||identity===exported.wgsl.fingerprint)});
        if(exported.bake)run.checks.push({name:'packaged_wgsl_seed_loaded',passed:run.console.some(text=>/seeded [1-9]\d* entries from bundled cache/.test(text))});
        run.checks.push({name:'wgsc_v4_persisted_identity',passed:run.persisted.length>0&&run.persisted.every(entry=>Buffer.from(entry.header).readUInt32LE(0)===0x43534757&&Buffer.from(entry.header).readUInt32LE(4)===4&&Buffer.from(entry.header.slice(8)).toString('hex')===identity)});
        if(temperature==='warm')run.checks.push({name:'warm_disk_cache_loaded',passed:run.console.some(text=>/\[WGSLCACHE\] loaded [1-9]\d* entries/.test(text))});
        if(exported.threads)run.checks.push({name:'workers_observed',passed:run.workers.length>0,detail:run.workers.length});
        run.runtimeErrors=run.errors.slice();
        run.runtimePassed=run.runtimeErrors.length===0&&run.console.some(text=>text.includes('BROWSER_DONE'))&&run.checks.every(check=>check.passed);
        await page.evaluate(()=>engine.requestQuit());
        await page.waitForFunction(()=>Number.isInteger(globalThis.__godotExit),{timeout:30000});
        run.exitCode=await page.evaluate(()=>globalThis.__godotExit);
        run.checks.push({name:'clean_engine_exit',passed:run.exitCode===0,detail:run.exitCode});
        await page.close();
        page.removeAllListeners();
        run.shutdownErrors=run.errors.slice(run.runtimeErrors.length);
        run.passed=run.errors.length===0&&run.console.some(text=>text.includes('BROWSER_DONE'))&&run.checks.every(check=>check.passed);
        await writeFile(join(output,`${name}-${temperature}.log`),run.console.join('\n')+'\n');
      }
      record.passed=record.runs.every(run=>run.passed);
    }catch(error){record.passed=false;record.error=String(error.stack||error);}
    finally{if(browser)await closeOwned(browser);await rm(profile,{recursive:true,force:true});}
    records.push(record);await writeFile(join(output,'result.json'),JSON.stringify({passed:records.every(r=>r.passed),exported,records},null,2)+'\n');console.log(JSON.stringify({browser:name,passed:record.passed,error:record.error,runs:record.runs.map(run=>({temperature:run.temperature,passed:run.passed,failed:run.checks?.filter(c=>!c.passed),errors:run.errors.slice(0,10)}))}));
  }
}finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
process.exit(records.every(record=>record.passed)?0:1);
