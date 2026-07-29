import os
import sys
from typing import TYPE_CHECKING

from methods import get_compiler_version, print_error, print_warning, using_gcc
from platform_methods import detect_arch, validate_arch

if TYPE_CHECKING:
    from SCons.Script.SConscript import SConsEnvironment


def get_name():
    return "SDL"


def can_build():
    if os.name != "posix" or sys.platform == "darwin":
        return False

    if os.system("pkg-config --version > /dev/null"):
        return False

    return True


def get_opts():
    from SCons.Variables import BoolVariable, EnumVariable

    return [
        EnumVariable("linker", "Linker program", "default", ["default", "bfd", "gold", "lld", "mold"], ignorecase=2),
        BoolVariable("use_llvm", "Use the LLVM compiler", False),
        BoolVariable("use_static_cpp", "Link libgcc and libstdc++ statically for better portability", True),
        BoolVariable("use_ubsan", "Use LLVM/GCC compiler undefined behavior sanitizer (UBSAN)", False),
        BoolVariable("use_asan", "Use LLVM/GCC compiler address sanitizer (ASAN)", False),
        BoolVariable("use_lsan", "Use LLVM/GCC compiler leak sanitizer (LSAN)", False),
        BoolVariable("use_tsan", "Use LLVM/GCC compiler thread sanitizer (TSAN)", False),
        BoolVariable("static_sdl", "Link SDL3 statically (uses `pkg-config sdl3 --static`)", False),
        BoolVariable("touch", "Enable touch events", True),
        BoolVariable("execinfo", "Use libexecinfo on systems where glibc is not available", False),
    ]


def get_flags():
    return {
        "arch": detect_arch(),
        "supported": ["mono"],
        # SDL is our joypad driver; the stripped-down copy vendored in
        # thirdparty/sdl has no video/audio subsystems, so the full system
        # (or sideloaded) SDL3 provides everything instead.
        "builtin_sdl": False,
    }


def configure(env: "SConsEnvironment"):
    # Validate arch.
    supported_arches = ["x86_32", "x86_64", "arm32", "arm64", "rv64"]
    validate_arch(env["arch"], get_name(), supported_arches)

    ## Compiler configuration

    if "CXX" in env and "clang" in os.path.basename(env["CXX"]):
        # Convenience check to enforce the use_llvm overrides when CXX is clang(++)
        env["use_llvm"] = True

    if env["use_llvm"]:
        if "clang++" not in os.path.basename(env["CXX"]):
            env["CC"] = "clang"
            env["CXX"] = "clang++"
        env.extra_suffix = ".llvm" + env.extra_suffix

    if env["linker"] != "default":
        print("Using linker program: " + env["linker"])
        if env["linker"] == "mold" and using_gcc(env):  # GCC < 12.1 doesn't support -fuse-ld=mold.
            cc_version = get_compiler_version(env)
            cc_semver = (cc_version["major"], cc_version["minor"])
            if cc_semver < (12, 1):
                print_error("Using mold with GCC < 12.1 is not supported by this platform port. Use lld or bfd.")
                sys.exit(255)
        env.Append(LINKFLAGS=["-fuse-ld=%s" % env["linker"]])

    if env["use_ubsan"] or env["use_asan"] or env["use_lsan"] or env["use_tsan"]:
        env.extra_suffix += ".san"
        if env["use_ubsan"]:
            env.Append(CPPDEFINES=["UBSAN_ENABLED"])
            env.Append(CCFLAGS=["-fsanitize=undefined"])
            env.Append(LINKFLAGS=["-fsanitize=undefined"])
        if env["use_asan"]:
            env.Append(CPPDEFINES=["ASAN_ENABLED"])
            env.Append(CCFLAGS=["-fsanitize=address"])
            env.Append(LINKFLAGS=["-fsanitize=address"])
        if env["use_lsan"]:
            env.Append(CPPDEFINES=["LSAN_ENABLED"])
            env.Append(CCFLAGS=["-fsanitize=leak"])
            env.Append(LINKFLAGS=["-fsanitize=leak"])
        if env["use_tsan"]:
            env.Append(CPPDEFINES=["TSAN_ENABLED"])
            env.Append(CCFLAGS=["-fsanitize=thread"])
            env.Append(LINKFLAGS=["-fsanitize=thread"])

    env.Append(CCFLAGS=["-ffp-contract=off"])

    # LTO

    if env["lto"] == "auto":  # Enable LTO for production.
        env["lto"] = "thin" if env["use_llvm"] else "full"

    if env["lto"] != "none":
        if env["lto"] == "thin":
            if not env["use_llvm"]:
                print_error("ThinLTO is only compatible with LLVM, use `use_llvm=yes` or `lto=full`.")
                sys.exit(255)
            env.Append(CCFLAGS=["-flto=thin"])
            env.Append(LINKFLAGS=["-flto=thin"])
        elif not env["use_llvm"] and env.GetOption("num_jobs") > 1:
            env.Append(CCFLAGS=["-flto"])
            env.Append(LINKFLAGS=["-flto=" + str(env.GetOption("num_jobs"))])
        else:
            env.Append(CCFLAGS=["-flto"])
            env.Append(LINKFLAGS=["-flto"])

        if not env["use_llvm"]:
            env["RANLIB"] = "gcc-ranlib"
            env["AR"] = "gcc-ar"

    env.Append(CCFLAGS=["-pipe"])

    ## Dependencies

    # This platform requires the full SDL3 for video/events/audio; the
    # stripped input-only copy in thirdparty/sdl cannot be used.
    if env["builtin_sdl"]:
        print_warning("The SDL platform cannot use the built-in (input-only) SDL. Forcing `builtin_sdl=no`.")
        env["builtin_sdl"] = False
    if not env["sdl"]:
        print_error("The SDL platform requires `sdl=yes`.")
        sys.exit(255)

    if os.system("pkg-config --exists sdl3"):
        print_error(
            "SDL3 development libraries not found (`pkg-config sdl3` failed).\n"
            "Install libsdl3-dev (or build SDL3 from source) and make sure it is\n"
            "visible to pkg-config (set PKG_CONFIG_PATH when using a custom prefix)."
        )
        sys.exit(255)

    if env["static_sdl"]:
        env.ParseConfig("pkg-config sdl3 --cflags --libs --static")
    else:
        env.ParseConfig("pkg-config sdl3 --cflags --libs")
    env.Append(CPPDEFINES=["SDL_ENABLED"])

    if env["touch"]:
        env.Append(CPPDEFINES=["TOUCH_ENABLED"])

    env.Prepend(CPPPATH=["#platform/sdl"])

    env.Append(
        CPPDEFINES=[
            "SDLPORT_ENABLED",
            "UNIX_ENABLED",
            ("_FILE_OFFSET_BITS", 64),
        ]
    )

    # core/SCsub only assembles zstd's x86_64 fast loops for the upstream
    # platform names, while zstd's own ZSTD_ASM_SUPPORTED check would still
    # reference them here, so disable the asm paths for this platform.
    env.Append(CPPDEFINES=["ZSTD_DISABLE_ASM"])

    if env["vulkan"]:
        env.Append(CPPDEFINES=["VULKAN_ENABLED", "RD_ENABLED"])
        if not env["use_volk"]:
            env.ParseConfig("pkg-config vulkan --cflags --libs")
        if not env["builtin_glslang"]:
            # No pkgconfig file so far, hardcode expected lib name.
            env.Append(LIBS=["glslang", "SPIRV", "glslang-default-resource-limits"])

    if env["opengl3"]:
        env.Append(CPPDEFINES=["GLES3_ENABLED"])
        # drivers/gl_context/SCsub only sets up GLAD for the upstream desktop
        # platforms, so do it ourselves (the glad sources are compiled from
        # this platform's SCsub). EGL_ENABLED lets the rasterizer resolve GL
        # symbols through eglGetProcAddress, which is what is available under
        # SDL's kmsdrm video driver.
        env.Prepend(CPPPATH=["#thirdparty/glad"])
        env.Append(CPPDEFINES=["GLAD_ENABLED", "GLAD_GLES2", "EGL_ENABLED"])

    env.Append(LIBS=["pthread", "dl"])

    import platform

    if platform.libc_ver()[0] != "glibc":
        if env["execinfo"]:
            env.Append(LIBS=["execinfo"])
            env.Append(CPPDEFINES=["CRASH_HANDLER_ENABLED"])
    else:
        env.Append(CPPDEFINES=["CRASH_HANDLER_ENABLED"])

    # Link those statically for portability
    if env["use_static_cpp"]:
        env.Append(LINKFLAGS=["-static-libgcc", "-static-libstdc++"])
        if env["use_llvm"]:
            env["LINKCOM"] = env["LINKCOM"] + " -l:libatomic.a"
    else:
        if env["use_llvm"]:
            env.Append(LIBS=["atomic"])
