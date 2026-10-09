#!/usr/bin/env python3
"""Compile the production isolation helpers with deterministic child behaviors."""

import argparse
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cxx", default="c++")
args = parser.parse_args()
source = (Path(__file__).resolve().parents[2] / "drivers/webgpu/tint_cli/main.cpp").read_text()
helpers = source[source.index("static bool write_all(") : source.index("static void print_usage()")]
harness = r"""
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <poll.h>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
static bool fail_pipe = false, fail_fork = false, short_writes = false;
static int interrupted_writes = 0;
static int test_pipe(int *fds) { if (fail_pipe) { errno = EMFILE; return -1; } return ::pipe(fds); }
static pid_t test_fork() { if (fail_fork) { errno = EAGAIN; return -1; } return ::fork(); }
static ssize_t test_write(int fd, const void *bytes, size_t size) {
    if (short_writes && interrupted_writes++ < 2) { errno = EINTR; return -1; }
    return ::write(fd, bytes, short_writes ? std::min(size, size_t(128)) : size);
}
static std::string convert_spirv_to_wgsl(const std::vector<uint8_t> &bytes, std::string &error) {
    switch (bytes[0]) {
        case 1: return std::string(256 * 1024, 'x');
        case 2: std::abort();
        case 3: usleep(2000000); return "late";
        case 4: error = "deliberate conversion error"; return {};
        case 5: return std::string(17 * 1024 * 1024, 'x');
        default: return "ok";
    }
}
#define pipe test_pipe
#define fork test_fork
#define write test_write
"""
harness += helpers
harness += r"""
#undef pipe
#undef fork
#undef write
#define CHECK(value) do { if (!(value)) { std::cerr << "FAIL line " << __LINE__ << ": " #value << "\n"; return 1; } passed++; } while (false)
int main() {
    int passed = 0;
    std::string error;
    CHECK(convert_isolated({0}, error) == "ok");
    short_writes = true;
    CHECK(convert_isolated({1}, error) == std::string(256 * 1024, 'x'));
    short_writes = false;
    CHECK(convert_isolated({2}, error).empty() && error.find("crashed") != std::string::npos);
    const auto started = std::chrono::steady_clock::now();
    CHECK(convert_isolated({3}, error, std::chrono::milliseconds(50)).empty() && error.find("timed out") != std::string::npos);
    CHECK(std::chrono::steady_clock::now() - started < std::chrono::seconds(1));
    CHECK(convert_isolated({4}, error).empty() && error == "deliberate conversion error");
    CHECK(convert_isolated({5}, error).empty() && error.find("16 MiB") != std::string::npos);
    fail_pipe = true;
    CHECK(convert_isolated({0}, error).empty() && error.find("pipe failed") != std::string::npos);
    fail_pipe = false;
    fail_fork = true;
    CHECK(convert_isolated({0}, error).empty() && error.find("fork failed") != std::string::npos);
    fail_fork = false;
    int status;
    CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    std::cout << "TINT_ISOLATION passed=" << passed << "\n";
}
"""
with tempfile.TemporaryDirectory(prefix="webgpu-tint-isolation-") as directory:
    root = Path(directory)
    cpp, binary = root / "test.cpp", root / "test"
    cpp.write_text(harness)
    subprocess.run([args.cxx, "-std=c++17", "-O1", str(cpp), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
