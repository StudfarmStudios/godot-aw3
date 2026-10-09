"""Scalar reference for SDFGI's quantized probe visibility, independent of packing."""

import math
import struct
from itertools import product


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


N = 16


def index(p):
    return (p[2] * N + p[1]) * N + p[0]


def inside(p):
    return all(0 <= x < N for x in p)


def add(a, b):
    return tuple(a[i] + b[i] for i in range(3))


def quantize(value):
    return max(0, min(255, int(math.floor(f32(value * 255.0) + 0.5))))


def reference(facing, parity=0):
    """Process ascending Manhattan distance from each probe, then both bias phases."""
    result = bytearray(N**3 * 8)
    octants = list(product(range(2), repeat=3))
    positions = sorted(product(range(8), repeat=3), key=sum)
    for slice_index in range(8):
        probe_offset = tuple(((slice_index ^ parity) >> axis) & 1 for axis in range(3))
        for region in product(*(range(2 - x) for x in probe_offset)):
            base = tuple((region[i] * 2 + probe_offset[i] - 1) * 8 for i in range(3))
            values = {}

            def face(p):
                return facing[index(p)] if inside(p) else 0

            def load(p):
                return f32(values.get(p, 0) / 255.0)

            for absolute in positions:
                for bits in octants:
                    signs = tuple(2 * x - 1 for x in bits)
                    local = tuple(8 + absolute[i] * signs[i] - (1 - bits[i]) for i in range(3))
                    point = add(base, local)
                    if not inside(point):
                        continue
                    if face(point):
                        visibility = 0.0
                    elif sum(absolute) == 0:
                        visibility = 1.0
                    else:
                        x, y, z = absolute
                        major = (1 if z < y else 2) if x < y else (0 if z < x else 2)
                        total, count = 0.0, 0
                        for axis in range(3):
                            delta = [0, 0, 0]
                            delta[axis] -= signs[axis]
                            if absolute[axis] == 0:
                                delta[major] -= signs[major]
                            neighbor = add(point, delta)
                            if face(neighbor) == 0:
                                if inside(neighbor):
                                    total = f32(total + load(neighbor))
                                    count += 1
                            elif absolute[axis] != 0:
                                count += 1
                        visibility = f32(total / count) if count else 0.0
                    values[point] = quantize(visibility)
            # Solid bias only reads empty cells, so this phase is order independent.
            for point in list(values):
                normal = face(point)
                if not normal:
                    continue
                local = tuple(point[i] - base[i] for i in range(3))
                direction = tuple(1 if x < 8 else -1 for x in local)
                valid = tuple(bool(normal & (1 << (axis if direction[axis] > 0 else axis + 3))) for axis in range(3))
                total, count = 0.0, 0
                for mask in range(1, 8):
                    if all(not (mask & (1 << axis)) or valid[axis] for axis in range(3)):
                        neighbor = add(point, tuple(direction[axis] if mask & (1 << axis) else 0 for axis in range(3)))
                        if inside(neighbor) and not face(neighbor):
                            total = f32(total + load(neighbor))
                            count += 1
                values[point] = quantize(f32(total / count) if count else 0.0)
            # Empty-cell bias checks immediate solid-facing visibility only.
            for point in list(values):
                if face(point):
                    continue
                local = tuple(point[i] - base[i] for i in range(3))
                direction = tuple(-1 if x < 8 else 1 for x in local)
                absolute = tuple(8 - x if x < 8 else x - 7 for x in local)
                visible, count = 0, 0
                for axis in range(3):
                    for sign in [1, -1]:
                        if (sign == 1 and absolute[axis] >= 8) or (sign == -1 and absolute[axis] != 1):
                            continue
                        delta = [0, 0, 0]
                        delta[axis] = direction[axis] * sign
                        neighbor = add(point, delta)
                        if inside(neighbor) and face(neighbor):
                            count += 1
                            bit = axis + 3 if delta[axis] > 0 else axis
                            visible += bool(face(neighbor) & (1 << bit))
                if count:
                    values[point] = quantize(f32(load(point) * f32(visible / count)))
            for point, value in values.items():
                result[slice_index * N**3 + index(point)] = value
    return bytes(result)
