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
    });
    lib_mod.linkLibrary(libxkbcommon.artifact("xkbcommon"));

    const exe = b.addExecutable(.{
        .name = "root",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("input_manager", lib_mod);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    b.getInstallStep().dependOn(&run_exe.step);
}
