const std = @import("std");
const app_name = "velora";
const version = parseZonVersion();

fn parseZonVersion() []const u8 {
    const zon = @embedFile("build.zig.zon");
    const prefix = ".version = \"";
    var i: usize = 0;
    while (i + prefix.len <= zon.len) : (i += 1) {
        if (std.mem.eql(u8, zon[i..][0..prefix.len], prefix)) {
            const start = i + prefix.len;
            var end = start;
            while (end < zon.len and zon[end] != '"') end += 1;
            return zon[start..end];
        }
    }
    return "0.0.0";
}

const CrossTarget = struct {
    name: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    abi: ?std.Target.Abi = null,
};

const cross_targets = [_]CrossTarget{
    .{ .name = "linux-x86_64", .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .name = "linux-aarch64", .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .name = "linux-arm", .cpu_arch = .arm, .os_tag = .linux },
    .{ .name = "linux-riscv64", .cpu_arch = .riscv64, .os_tag = .linux },
    .{ .name = "linux-s390x", .cpu_arch = .s390x, .os_tag = .linux },
    .{ .name = "linux-ppc64le", .cpu_arch = .powerpc64le, .os_tag = .linux },
    .{ .name = "linux-i386", .cpu_arch = .x86, .os_tag = .linux },
    .{ .name = "linux-loongarch64", .cpu_arch = .loongarch64, .os_tag = .linux },
    .{ .name = "alpine-x86_64", .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .name = "alpine-aarch64", .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .name = "alpine-arm", .cpu_arch = .arm, .os_tag = .linux, .abi = .musl },
    .{ .name = "windows-x86_64", .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .name = "windows-i386", .cpu_arch = .x86, .os_tag = .windows },
    .{ .name = "windows-aarch64", .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .name = "macos-x86_64", .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .name = "macos-aarch64", .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .name = "freebsd-x86_64", .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .name = "freebsd-aarch64", .cpu_arch = .aarch64, .os_tag = .freebsd },
};

fn addVersionModule(b: *std.Build, module: *std.Build.Module) void {
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    module.addImport("build_options", options.createModule());
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // On Windows hosts, letting the default install graph fan out many LLVM
    // cross-compiles in parallel can trigger OOM / `error: Unexpected` failures.
    // Serialize the compile graph explicitly instead of relying on build-runner
    // memory accounting, which can itself hit assertions on Zig 0.15.2.
    var previous_compile_step: ?*std.Build.Step = null;
    var previous_install_step: ?*std.Build.Step = null;

    for (cross_targets) |ct| {
        const ct_target = b.resolveTargetQuery(.{
            .cpu_arch = ct.cpu_arch,
            .os_tag = ct.os_tag,
            .abi = ct.abi,
        });

        const ct_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = ct_target,
            .optimize = optimize,
        });
        addVersionModule(b, ct_module);

        const ct_exe = b.addExecutable(.{
            .name = b.fmt("{s}-{s}", .{ app_name, ct.name }),
            .root_module = ct_module,
        });
        if (previous_compile_step) |prev| {
            ct_exe.step.dependOn(prev);
        }
        previous_compile_step = &ct_exe.step;

        const ct_install = b.addInstallArtifact(ct_exe, .{});
        if (previous_install_step) |prev| {
            ct_install.step.dependOn(prev);
        }
        b.getInstallStep().dependOn(&ct_install.step);
        previous_install_step = &ct_install.step;
    }

    const native_target = b.standardTargetOptions(.{});

    const native_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    addVersionModule(b, native_module);

    const native_exe = b.addExecutable(.{
        .name = app_name,
        .root_module = native_module,
    });
    if (previous_compile_step) |prev| {
        native_exe.step.dependOn(prev);
    }

    const native_install = b.addInstallArtifact(native_exe, .{});
    if (previous_install_step) |prev| {
        native_install.step.dependOn(prev);
    }
    b.getInstallStep().dependOn(&native_install.step);

    const run_cmd = b.addRunArtifact(native_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run velora (native)");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    addVersionModule(b, test_module);

    const exe_unit_tests = b.addTest(.{
        .name = "velora-test",
        .root_module = test_module,
    });
    exe_unit_tests.step.dependOn(&native_exe.step);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
