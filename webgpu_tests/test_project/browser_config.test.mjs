import test from 'node:test';
import assert from 'node:assert/strict';
import { assertForwardPlusLimits, launchOptions, requiredForwardPlusLimits } from './browser_config.mjs';

test('exact Forward+ minimums and greater physical limits pass', () => {
    assert.doesNotThrow(() => assertForwardPlusLimits(requiredForwardPlusLimits));
    assert.doesNotThrow(() => assertForwardPlusLimits({
        maxSampledTexturesPerShaderStage: 64,
        maxStorageTexturesPerShaderStage: 16,
        maxStorageBuffersPerShaderStage: 12,
    }, 'device'));
});

for (const label of ['adapter', 'device']) {
    for (const [name, minimum] of Object.entries(requiredForwardPlusLimits)) {
        test(`${label} rejects insufficient ${name}`, () => {
            assert.throws(() => assertForwardPlusLimits({
                ...requiredForwardPlusLimits, [name]: minimum - 1,
            }, label), (error) => error.message.includes(label)
                && error.message.includes(`${name}=${minimum - 1}`)
                && error.message.includes(`requires >=${minimum}`));
        });
    }
}

test('missing and invalid reported limits fail closed', () => {
    for (const limits of [undefined, null, {}, {
        ...requiredForwardPlusLimits, maxStorageTexturesPerShaderStage: NaN,
    }, {
        ...requiredForwardPlusLimits, maxStorageTexturesPerShaderStage: Infinity,
    }, {
        ...requiredForwardPlusLimits, maxStorageTexturesPerShaderStage: '8',
    }]) {
        assert.throws(() => assertForwardPlusLimits(limits), /cannot support Forward\+/);
    }
});

test('prototype-backed GPUSupportedLimits getters are accepted', () => {
    const limits = Object.create(Object.fromEntries(Object.entries(requiredForwardPlusLimits)));
    assert.doesNotThrow(() => assertForwardPlusLimits(limits));
});

test('Linux explicitly selects SwiftShader and disables only tier rounding', () => {
    const options = launchOptions('linux');
    assert.equal(options.headless, false);
    assert.ok(options.args.includes('--use-gl=angle'));
    assert.ok(options.args.includes('--use-angle=swiftshader'));
    assert.ok(!options.args.includes('--use-angle=vulkan'));
    assert.ok(options.args.includes('--use-vulkan=swiftshader'));
    assert.ok(options.args.includes('--use-webgpu-adapter=swiftshader'));
    assert.deepEqual(options.args.filter((argument) => argument.startsWith('--disable-dawn-features=')), [
        '--disable-dawn-features=tiered_adapter_limits',
    ]);
    assert.ok(options.args.every((argument) => !argument.includes('skip_validation')));
});

test('non-Linux launches retain the existing backend settings', () => {
    for (const platform of ['darwin', 'win32']) {
        assert.deepEqual(launchOptions(platform), {
            headless: false,
            args: [
                '--enable-unsafe-webgpu',
                '--enable-features=Vulkan,UseSkiaRenderer',
                '--disable-gpu-sandbox',
                '--use-angle=vulkan',
            ],
        });
    }
});

test('one caller cannot modify later launch options or the minimums', () => {
    launchOptions('linux').args.push('--unexpected');
    assert.ok(!launchOptions('linux').args.includes('--unexpected'));
    assert.ok(Object.isFrozen(requiredForwardPlusLimits));
});
