const std = @import("std");

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary.");

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const module = b.addModule("adblock_webkit_convert", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe_module.addImport("adblock_webkit_convert", module);
    exe_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "adblock-webkit-convert",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run the converter").dependOn(&run.step);

    const unit_tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}
