const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("input_manager", .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkSystemLibrary("udev", .{
        // Don't know why it works, but it does :)
        .use_pkg_config = .no,
    });
    lib_mod.linkSystemLibrary("evdev", .{});

    const libxkbcommon = b.dependency("libxkbcommon", .{
        .target = target,
        .optimize = optimize,
        .@"xkb-config-root" = "/usr/share/X11/xkb",
        .@"xkb-legacy-root" = "/usr/share/X11/xkb",
        // Compose tables, for the dead keys. The default is under the install
        // prefix, where there are none.
        .@"x-locale-root" = "/usr/share/X11/locale",
    });
    lib_mod.linkLibrary(libxkbcommon.artifact("xkbcommon"));

    const use_llvm = b.option(bool, "use_llvm", "Enable to force use of llvm");
    const use_lld = b.option(bool, "use_lld", "Enable to force use of lld");

    const exe = b.addExecutable(.{
        .name = "root",
        .use_llvm = use_llvm,
        .use_lld = use_lld,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("input_manager", lib_mod);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the test app");

    run_step.dependOn(&run_exe.step);

    // Needs the XKB data and compose tables of the system, not /dev/input.
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
