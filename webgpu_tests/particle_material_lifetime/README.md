# Particle material shader lifetime

`ParticleProcessMaterial::MaterialKey` has 20 named fields occupying 46 bits,
with 18 padding bits on the tested platform. Hashing/comparing the entire struct
made equal field values differ after copies or return-by-value. A native trace
showed a hash change immediately across `current_key = mk`, one registered owner,
and a destructor lookup miss. There was no recursive registration.

The repair packs named fields into a `uint64_t` for hashing, equality and ordering.
It preserves the invalid-key sentinel, every parameter/flag width, and existing
cache locking and owner counts.

The standalone test extracts the actual key, enum declarations and hash function
from production source. With ASan+UBSan it checks all field bits, changed padding,
copy construction, assignment, by-value return, placement construction and real
hash-map lookup/erase. The old key fails 170 of 340 checks; the corrected key passes
340/340, representing 47 distinct keys. Neither run reports sanitizer errors.

The native fixture creates four materials sharing a shader, renders particles,
repeats material lookups, and checks both explicit destruction and ordinary scene
shutdown. It checks the complete process output because late RID diagnostics
can arrive after the engine log closes. The old editor fails all four cases
(Metal/WebGPU × runtime/shutdown) with a particle shader and shader RID leak.
The corrected editor passes all four with clean exit and expected weak-reference
counts. The complete broad Metal scene that originally exposed the leak also
finishes without errors or leaked RIDs. These are lifetime checks, not pixel
quality or performance measurements. Windows/browser runtime coverage is not
claimed by this fixture.

Compact results preserve both binary hashes and the negative controls in
`results/`. Final editor `8ef30015…` passes all four cases, including the enum
casts in the size assertion. Earlier `1a8dd0de…` positives and its broad Metal
run remain separately identified; the casts do not change runtime behavior.

```sh
python3 webgpu_tests/particle_material_lifetime/test_material_key.py --output /tmp/particle-key
python3 webgpu_tests/particle_material_lifetime/run_native.py /path/to/editor --output /tmp/particle-native
```

For a previous header, use `--header /path/to/header --expect-failure` with the
standalone test. Select native backends with `--drivers metal` or
`--drivers webgpu`; both are tested by default. Compiled test programs, private
project copies and full engine logs stay in the requested output directory.
