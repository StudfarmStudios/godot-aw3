# Production logical-copy lowering regressions

```sh
bash drivers/webgpu/tint_cli/build.sh
python3 webgpu_tests/spirv_preprocess/run_logical_copy.py --output /tmp/logical-copy-results
```

Requires clang++, SPIRV-Tools (`spirv-as`, `spirv-val`) and glslang. The harness
compiles the production preprocessor with AddressSanitizer/UndefinedBehaviorSanitizer,
reusing the bundled SPIRV-Tools objects from the Tint CLI build.

34 checks cover 17 valid aggregate-copy cases, 16 malformed/resource-limit guards
and identical-type canonicalization. Producers include constants, nulls, loads,
extracts, inserts, constructors, phi/select, calls, parameters and chained copies.
The old opcode-only rewrite fails all 17 valid regression cases. Fourteen valid
cases also translate through Tint after explicitly test-only SPIR-V 1.3 interface
normalization. Production does not downgrade the module version: aggregate
`OpSelect` and other newer semantics need a separately reviewed Tint/normalization
bundle. The suite checks preserved result IDs, validation, idempotence, safe
all-or-nothing rejection and bounded expansion.
