const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lambda_module = b.addModule("lambda", .{
        .root_source_file = b.path("src/lambda.zig"),
        .link_libc = true,
    });

    // Unit tests
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lambda.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Examples
    inline for ([_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{ .name = "echo", .src = "examples/echo/main.zig" },
        .{ .name = "apigw", .src = "examples/apigw/main.zig" },
    }) |example| {
        const example_step = b.step(
            example.name ++ "-example",
            "build the " ++ example.name ++ " example",
        );

        const exe = b.addExecutable(.{
            .name = "bootstrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.src),
                .target = target,
                .optimize = optimize,
            }),
        });

        exe.root_module.addImport("lambda", lambda_module);
        exe.root_module.link_libc = true;

        const install_step = b.addInstallArtifact(exe, .{});
        example_step.dependOn(&install_step.step);
    }
}
