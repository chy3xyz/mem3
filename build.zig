const std = @import("std");

/// Build script for TriSource-EverOS / mem3
/// Zig 0.17 dev (>= 0.17.0-dev.3000) build system API.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // Main executable: `mem3`
    // =========================================================================
    const mem3_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "mem3",
        .root_module = mem3_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run mem3");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // Test step
    // =========================================================================
    const test_step = b.step("test", "Run all tests");
    addAllTests(b, test_step, target, optimize);

    // =========================================================================
    // Bench step
    // =========================================================================
    const bench_step = b.step("bench", "Run performance benchmarks");
    addBench(b, bench_step, target);

    // =========================================================================
    // Static library (for C ABI, future use)
    // =========================================================================
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "mem3",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Expose modules for example/test imports.
    const ghw_module = b.createModule(.{
        .root_source_file = b.path("src/ghw/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const memory_module = b.createModule(.{
        .root_source_file = b.path("src/memory/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = ghw_module;
    _ = memory_module;

    // The lib.zig-based "libmem3" module that examples can import.
    const libmem3_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // Constitution check (CI gate)
    // =========================================================================
    const constitution_check = b.step("check-constitution", "Run constitution invariants");
    addConstitutionChecks(b, constitution_check, target, optimize);

    // =========================================================================
    // Example: `zig build example-notebook`
    // =========================================================================
    const notebook_module = b.createModule(.{
        .root_source_file = b.path("examples/notebook.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mem3", .module = libmem3_module },
        },
    });
    const notebook_exe = b.addExecutable(.{
        .name = "notebook",
        .root_module = notebook_module,
    });
    b.installArtifact(notebook_exe);
    const run_notebook = b.addRunArtifact(notebook_exe);
    const notebook_step = b.step("example-notebook", "Run the researcher's notebook example");
    notebook_step.dependOn(&run_notebook.step);
}

fn addAllTests(
    b: *std.Build,
    parent_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    parent_step.dependOn(&run_tests.step);
}

fn addBench(
    b: *std.Build,
    parent_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
) void {
    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{
        .name = "mem3-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    parent_step.dependOn(&run_bench.step);
}

fn addConstitutionChecks(
    b: *std.Build,
    parent_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mem3_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const constitution_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/constitution/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mem3", .module = mem3_module },
            },
        }),
    });
    const run_const = b.addRunArtifact(constitution_tests);
    parent_step.dependOn(&run_const.step);
}
