#!/usr/bin/env node
// Real browser WebGPU, isolated profile, fixed fixture PCK and replaceable runtime.
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {readFile,writeFile,mkdir,mkdtemp,rm} from 'node:fs/promises';
import {resolve,join,extname,sep} from 'node:path';
import {tmpdir} from 'node:os';
import {checkPhase} from './pixel_checks.mjs';
const args=Object.fromEntries(process.argv.slice(2).map(value=>value.replace(/^--/,'').split('=')));
if(!args.export||!args.output||!args['node-modules'])throw new Error('Use --export=/path/export --output=/path/results --node-modules=/path/package.json [--runtime=/path/game-web-baseline] [--browser=chrome,firefox]');
const root=resolve(args.export),runtime=resolve(args.runtime||args.export),output=resolve(args.output);
const require=createRequire(resolve(args['node-modules'])),puppeteer=require('puppeteer-core'),{PNG}=require('pngjs');
const timeout=Number(args.timeout||180000),fallback='fallback' in args;
await mkdir(output,{recursive:true});
const hashes={};
for(const [name,path] of Object.entries({html:join(root,'index.html'),pck:join(root,'index.pck'),js:join(runtime,'index.js'),wasm:join(runtime,'index.wasm')})){
  const contents=await readFile(path);hashes[name]={path,bytes:contents.length,sha256:createHash('sha256').update(contents).digest('hex')};
}
const mime={'.html':'text/html','.js':'text/javascript','.wasm':'application/wasm','.json':'application/json','.png':'image/png'};
const server=createServer(async(request,response)=>{
  try{
    const pathname=decodeURIComponent(new URL(request.url,'http://localhost').pathname);
    if(pathname==='/favicon.ico'){response.writeHead(204);response.end();return;}
    // Only runtime artifacts come from the candidate. The fixture HTML/PCK are immutable.
    const fromRuntime=pathname==='/index.js'||pathname==='/index.wasm'||pathname.endsWith('.worklet.js');
    const base=fromRuntime?runtime:root;
    const path=resolve(base,'.'+(pathname==='/'?'/index.html':pathname));
    if(!path.startsWith(base+sep))throw new Error('Outside export directory');
    let contents=await readFile(path);
    if(extname(path)==='.html') {
      let replacements=0;
      contents=Buffer.from(contents.toString().replace('<canvas id="canvas">','<canvas id="canvas" width="96" height="64">').replace(/const GODOT_CONFIG = (\{[^\n]+\});/,(_,json)=>{
        replacements++;
        const config=JSON.parse(json);
        config.args=['--verbose','--rendering-method','forward_plus','--rendering-driver','webgpu','--render-thread','separate',...(fallback?['--','--webgpu-force-fallbacks','--webgpu-no-float32-filterable']:[])];
        config.renderingDriver='webgpu';config.canvasResizePolicy=0;
        config.fileSizes['index.wasm']=hashes.wasm.bytes;
        return 'const GODOT_CONFIG = '+JSON.stringify(config)+'; GODOT_CONFIG.onExit=(code)=>{globalThis.__godotExit=code;};';
      }));
      if(replacements!==1)throw new Error('Fixture export lacks one GODOT_CONFIG');
    }
    response.writeHead(200,{'Content-Type':mime[extname(path)]||'application/octet-stream','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cache-Control':'no-store'});response.end(contents);
  }catch(error){response.writeHead(404);response.end(String(error));}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const url=`http://127.0.0.1:${server.address().port}/index.html`,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function closeOwned(browser){
  const process=browser.process();let timer;
  try{await Promise.race([browser.close().catch(()=>{}),new Promise(resolve=>{timer=setTimeout(resolve,10000);})]);if(process?.exitCode===null&&process?.signalCode===null)process.kill('SIGKILL');}
  finally{clearTimeout(timer);for(const stream of process?.stdio||[])stream?.destroy?.();}
}
const records=[];
try{
  for(const name of (args.browser||'chrome,firefox').split(',')){
    if(!['chrome','firefox'].includes(name))throw new Error('Unsupported browser');
    const record={browser:name,fallback,passed:false,console:[],errors:[],checks:[],phases:[],workers:[]};records.push(record);
    const profile=await mkdtemp(join(tmpdir(),'aw3-dynamic-bg-'));let browser;
    try{
      browser=await puppeteer.launch({browser:name,executablePath:name==='firefox'?(args['firefox-bin']||'/Applications/Firefox.app/Contents/MacOS/firefox'):(args['chrome-bin']||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),userDataDir:profile,headless:false,defaultViewport:{width:96,height:64,deviceScaleFactor:1},timeout:60000,protocolTimeout:timeout});
      const page=await browser.newPage();
      record.version=await browser.version();
      page.on('console',message=>{
        const text=message.text();record.console.push(text);
        // Godot also writes ordinary warnings to stderr; reject actual errors, not the transport alone.
        if(/(^|\s)(ERROR:|SCRIPT ERROR:|SHADER ERROR:)|GPUValidationError|uncaptured error|device lost|Aborted\(|RuntimeError|Tint.*fail|SPIR-V.*fail/i.test(text))record.errors.push(text);
      });
      page.on('pageerror',error=>record.errors.push(String(error.stack||error)));
      page.on('workercreated',worker=>record.workers.push(worker.url()));
      page.on('requestfailed',request=>record.errors.push('Request failed: '+request.url()+' '+request.failure()?.errorText));
      await page.goto(url,{waitUntil:'domcontentloaded',timeout});
      record.capabilities=await page.evaluate(()=>({crossOriginIsolated,webgpu:!!navigator.gpu,userAgent:navigator.userAgent}));
      for(let phase=0;phase<12;phase++){
        const deadline=Date.now()+timeout;
        let message;
        while(!(message=record.console.map(line=>line.match(/DYNAMIC_BIND_GROUP PHASE (\{.*\})/)).filter(Boolean).map(match=>JSON.parse(match[1])).find(value=>value.phase===phase))){
          if(record.errors.length)throw new Error(record.errors.join('\n'));
          if(Date.now()>deadline)throw new Error('Timeout waiting for phase '+phase);
          await sleep(50);
        }
        if(message.width!==96||message.height!==64)throw new Error('Wrong engine viewport dimensions');
        await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
        const canvas=await page.$('canvas');if(!canvas)throw new Error('Missing canvas');
        const dimensions=await canvas.evaluate(element=>({width:element.width,height:element.height}));
        if(dimensions.width!==96||dimensions.height!==64)throw new Error('Wrong canvas dimensions: '+JSON.stringify(dimensions));
        const screenshot=await canvas.screenshot({path:join(output,`${name}-${phase}.png`)});
        const checks=checkPhase(PNG.sync.read(Buffer.from(screenshot)),phase);record.checks.push(...checks);record.phases.push({...message,canvas:dimensions});
        if(checks.some(check=>!check.passed))throw new Error('Pixel failure in phase '+phase);
        await canvas.click({offset:{x:1,y:1}});await page.keyboard.press(' ');
      }
      const deadline=Date.now()+10000;
      while(!record.console.some(text=>text.includes('DYNAMIC_BIND_GROUP BROWSER_DONE phases=12'))&&Date.now()<deadline)await sleep(50);
      if(!record.console.some(text=>text.includes('DYNAMIC_BIND_GROUP BROWSER_DONE phases=12')))throw new Error('Missing engine completion');
      if(!record.console.some(text=>text.includes('DYNAMIC_BIND_GROUP DRIVER webgpu method=forward_plus')))throw new Error('Actual WebGPU Forward+ renderer not confirmed');
      if(fallback&&!record.console.some(text=>text.includes('float32-filterable feature NOT available')))throw new Error('Fallback feature omission not confirmed');
      if(!record.capabilities.crossOriginIsolated||!record.capabilities.webgpu||!record.workers.length)throw new Error('Missing isolated threaded WebGPU capabilities');
      await page.evaluate(()=>engine.requestQuit());
      await page.waitForFunction(()=>Number.isInteger(globalThis.__godotExit),{timeout:30000});
      record.exitCode=await page.evaluate(()=>globalThis.__godotExit);await sleep(1000);
      if(record.exitCode!==0)throw new Error('Nonzero engine exit');
      record.passed=record.errors.length===0&&record.checks.length===192&&record.checks.every(check=>check.passed);
    }catch(error){record.error=String(error.stack||error);}
    finally{if(browser)await closeOwned(browser);await rm(profile,{recursive:true,force:true});}
    await writeFile(join(output,`${name}.log`),record.console.join('\n')+'\n');
    await writeFile(join(output,'result.json'),JSON.stringify({passed:records.every(record=>record.passed),hashes,records},null,2)+'\n');
    console.log(JSON.stringify({browser:name,passed:record.passed,checks:record.checks.length,error:record.error,errors:record.errors}));
  }
}finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
process.exit(records.every(record=>record.passed)?0:1);
