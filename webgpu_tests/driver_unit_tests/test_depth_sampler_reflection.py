#!/usr/bin/env python3
"""Compile the driver's actual WGSL reflection functions and test sampler keys.

Only String/HashMap/HashSet storage is substituted so this runs without a full
Godot link. The parser and association logic are extracted from the driver;
there is no second implementation of the behavior under test.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DRIVER = ROOT / 'drivers/webgpu/rendering_device_driver_webgpu.cpp'
SHIMS = r'''
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>
struct String : std::string {
    using std::string::string;
    static String utf8(const char *s, int n) { return String(s, n); }
};
template<class K, class V> struct HashMap {
    std::vector<std::pair<K,V>> values;
    void insert(const K &k, const V &v) {
        for (auto &p : values) if (p.first == k) { p.second = v; return; }
        values.emplace_back(k,v);
    }
    const V *getptr(const K &k) const {
        for (const auto &p : values) if (p.first == k) return &p.second;
        return nullptr;
    }
    bool has(const K &k) const { return getptr(k) != nullptr; }
};
template<class K> struct HashSet {
    std::vector<K> values;
    void insert(const K &k) { if (!has(k)) values.push_back(k); }
    bool has(const K &k) const { return std::find(values.begin(), values.end(), k) != values.end(); }
    bool is_empty() const { return values.empty(); }
};
'''
MAIN = r'''
int main() {
    std::string code((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
    HashSet<uint32_t> keys;
    _collect_depth_paired_samplers(code.c_str(), &keys);
    std::sort(keys.values.begin(), keys.values.end());
    for (uint32_t key : keys.values) std::cout << key << '\n';
}
'''
DECLARATIONS = '''
@group(1u) @binding(12u) var directional_shadow_atlas : texture_depth_2d;
@group(1u) @binding(24u) var SAMPLER_NEAREST_CLAMP : sampler;
@group(1u) @binding(26u) var linear_sampler : sampler;
@group(0u) @binding(8u) var shadow_sampler : sampler_comparison;
@group(2u) @binding(3u) var colour : texture_2d<f32>;
'''

class DepthSamplerReflection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='godot-depth-samplers-')
        directory = pathlib.Path(cls.temp.name)
        source = DRIVER.read_text()
        parse = source[source.index('static bool parse_group_binding('):source.index('\n// =============================================================================\n// SPIR-V', source.index('static bool parse_group_binding('))]
        collect = source[source.index('static void _collect_depth_paired_samplers('):source.index('\nstatic char *_translate_spirv_to_wgsl(')]
        cpp = directory / 'reflection.cpp'
        cpp.write_text(SHIMS + parse + collect + MAIN)
        cls.binary = directory / 'reflection'
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def keys(self, body):
        result = subprocess.run([str(self.binary)], input=DECLARATIONS + body,
                                text=True, capture_output=True, check=True)
        return {int(key) for key in result.stdout.splitlines()}

    def test_direct_depth_use(self):
        self.assertEqual(self.keys('''fn main() {
            let d = textureSampleLevel(directional_shadow_atlas, SAMPLER_NEAREST_CLAMP, vec2<f32>(0.5), 0);
        }'''), {(1 << 16) | 24})

    def test_soft_shadow_helper(self):
        # Minimized from the captured Forward+ directional soft-shadow shader.
        self.assertEqual(self.keys('''fn soft_shadow(shadow : texture_depth_2d, uv : vec2<f32>) -> f32 {
            if (uv.x > 0.0) {
                return textureSampleLevel(shadow, SAMPLER_NEAREST_CLAMP, uv, 0);
            }
            return textureSampleCompare(shadow, shadow_sampler, uv, 0.5);
        }
        fn main() { let d = soft_shadow(directional_shadow_atlas, vec2<f32>(0.5)); }
        '''), {(1 << 16) | 24})

    def test_parameter_names_are_scoped(self):
        self.assertEqual(self.keys('''fn depth(shadow : texture_depth_2d) -> f32 {
            return textureSampleLevel(shadow, SAMPLER_NEAREST_CLAMP, vec2<f32>(0.5), 0);
        }
        fn colour_read(shadow : texture_2d<f32>) -> vec4<f32> {
            return textureSampleLevel(shadow, linear_sampler, vec2<f32>(0.5), 0);
        }
        '''), {(1 << 16) | 24})

    def test_parameter_can_shadow_global_texture_name(self):
        self.assertEqual(self.keys('''fn colour_read(directional_shadow_atlas : texture_2d<f32>) -> vec4<f32> {
            return textureSampleLevel(directional_shadow_atlas, linear_sampler, vec2<f32>(0.5), 0);
        }'''), set())

    def test_comparison_and_load_are_not_filtering_pairs(self):
        self.assertEqual(self.keys('''fn compare(shadow : texture_depth_2d) -> f32 {
            let d = textureLoad(shadow, vec2<i32>(0), 0);
            return textureSampleCompareLevel(shadow, shadow_sampler, vec2<f32>(0.5), d);
        }'''), set())

    def test_empty_shader(self):
        self.assertEqual(self.keys('fn main() {}'), set())

if __name__ == '__main__':
    unittest.main()
