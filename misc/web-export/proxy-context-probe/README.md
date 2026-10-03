# Proxy context lifetime regression

Threaded Web builds using an affected Emscripten SDK (including 4.0.20) link a
generated copy of that SDK's `proxying.c` with the ordering fix from
[Emscripten #26582](https://github.com/emscripten-core/emscripten/pull/26582).
Both completion and cancellation signal the condition variable before releasing
the mutex. Otherwise the caller can observe completion, return, and reuse the
stack containing the context before the target signals it.

The generated object supplies the SDK source's symbols before libc is searched.
The installed SDK and its cached libraries are unchanged. SDKs containing the
upstream fix use their own implementation; an unknown source layout fails the
build so a different runtime cannot silently receive this backport.

This probe uses test-only hooks in separate source copies to force the caller to
return before the target finishes signaling. The caller then allocates a new
stack buffer over the retired context. The affected implementation traps with
`operation does not support unaligned accesses`; the fixed implementation passes
and completes another 40,000 synchronous calls from four concurrent callers.
The hooks and stack pattern are never included in the engine build.

```sh
python3 misc/web-export/proxy-context-probe/build.py \
  --emscripten-dir "$EMSDK/upstream/emscripten" --output /tmp/proxy-context
# Serve /tmp/proxy-context with COOP: same-origin and COEP: require-corp headers.
node misc/web-export/proxy-context-probe/run.mjs http://127.0.0.1:8000/ \
  /path/to/node_modules/puppeteer-core /tmp/proxy-context-results.json
```

The runner uses installed Chrome (`CHROME_BIN` overrides its macOS path). It
requires the original implementation to fail with the expected memory error and
then runs the fixed implementation three times. It writes browser identity,
console messages, errors, and results to the requested JSON file.
