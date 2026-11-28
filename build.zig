const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const exe = b.addExecutable(.{
        .name = "zhdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.link_libc = true;
    linkPlatformLibs(b, exe.root_module, target.result.os.tag);
    const support = b.dependency("zhdb_support", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("btree", support.module("btree"));
    exe.root_module.addImport("lz4", support.module("lz4"));
    exe.root_module.addImport("regex", support.module("regex"));
    exe.root_module.addImport("tls", support.module("tls"));
    exe.root_module.addImport("mutex_alloc", support.module("mutex_alloc"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zhdb");
    run_step.dependOn(&run_cmd.step);

    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit.root_module.link_libc = true;
    linkPlatformLibs(b, unit.root_module, target.result.os.tag);
    unit.root_module.addImport("btree", support.module("btree"));
    unit.root_module.addImport("lz4", support.module("lz4"));
    unit.root_module.addImport("regex", support.module("regex"));
    unit.root_module.addImport("tls", support.module("tls"));
    unit.root_module.addImport("mutex_alloc", support.module("mutex_alloc"));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

/// iconv lives in glibc on Linux and in libiconv/libicucore on macOS. Linking
/// them unconditionally breaks Linux builds (and CI), so only request the
/// platform libraries that actually exist.
fn linkPlatformLibs(b: *std.Build, mod: *std.Build.Module, os: std.Target.Os.Tag) void {
    switch (os) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            mod.linkSystemLibrary("iconv", .{});
            mod.linkSystemLibrary("icucore", .{});
        },
        .linux => {
            mod.linkSystemLibrary("icuuc", .{});
            mod.addCSourceFile(.{
                .file = b.path("src/icu_shim.c"),
                .flags = &.{"-I/usr/include"},
            });
        },
        else => {},
    }
}
