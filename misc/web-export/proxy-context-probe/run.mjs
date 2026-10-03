// Usage: node run.mjs URL PUPPETEER_CORE_DIRECTORY OUTPUT_JSON
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const [base, puppeteerPath, output] = process.argv.slice(2);
if (!base || !puppeteerPath || !output) throw new Error('Usage: run.mjs URL PUPPETEER_CORE_DIRECTORY OUTPUT_JSON');
const require = createRequire(import.meta.url);
const puppeteer = require(resolve(puppeteerPath));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: false,
});
const results = [];
try {
  for (const mode of ['before', 'after', 'after', 'after']) {
    const page = await browser.newPage();
    const result = { mode, messages: [], errors: [] };
    page.on('console', message => {
      result.messages.push(message.text());
      if (/RuntimeError|PROXY_CONTEXT_FAIL|Aborted/.test(message.text())) result.errors.push(message.text());
    });
    page.on('pageerror', error => result.errors.push(String(error)));
    await page.goto(new URL(`${mode}.html`, base).href);
    const deadline = Date.now() + 60000;
    while (Date.now() < deadline && !result.errors.length && !result.messages.some(m => m.includes('PROXY_CONTEXT_PASS'))) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    result.passed = mode === 'before'
      ? result.errors.some(error => /unaligned accesses|memory access out of bounds/.test(error))
      : result.errors.length === 0 && result.messages.some(m => m.includes('PROXY_CONTEXT_PASS forced_stack_reuse=1 sync_calls=40001'));
    results.push(result);
    console.log(JSON.stringify(result));
    await page.close();
    if (!result.passed) throw new Error(`${mode} did not produce the expected result`);
  }
} finally {
  await writeFile(resolve(output), JSON.stringify({ browser: await browser.version(), results }, null, 2) + '\n');
  await browser.close();
}
