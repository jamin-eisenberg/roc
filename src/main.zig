//! Roc command line interface for the new compiler. Entrypoint of the Roc binary.
//! Build with `zig build -Dllvm -Dfuzz -Dsystem-afl=false`.
//! Result is at `./zig-out/bin/roc`

const std = @import("std");
const fmt = @import("fmt.zig");
const base = @import("base.zig");
const collections = @import("collections.zig");
const coordinate = @import("coordinate.zig");
const problem_mod = @import("problem.zig");
const tracy = @import("tracy.zig");
const Filesystem = @import("coordinate/Filesystem.zig");
const cli_args = @import("cli_args.zig");

const Problem = problem_mod.Problem;
const Allocator = std.mem.Allocator;
const exitOnOom = collections.utils.exitOnOom;
const fatal = collections.utils.fatal;

const legalDetailsFileContent = @embedFile("legal_details");

/// The CLI entrypoint for the Roc compiler.
pub fn main() !void {
    var gpa_tracy: tracy.TracyAllocator(null) = undefined;
    var gpa = std.heap.c_allocator;

    if (tracy.enable_allocation) {
        gpa_tracy = tracy.tracyAllocator(gpa);
        gpa = gpa_tracy.allocator();
    }

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);

    const result = mainArgs(gpa, arena, args);
    if (tracy.enable) {
        try tracy.waitForShutdown();
    }
    return result;
}

fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    const parsed_args = cli_args.parse(gpa, args[1..]);
    defer parsed_args.deinit(gpa);
    try switch (parsed_args) {
        .run => |run_args| rocRun(gpa, run_args),
        .check => |check_args| rocCheck(gpa, check_args),
        .build => |build_args| rocBuild(gpa, build_args),
        .format => |format_args| rocFormat(gpa, arena, format_args),
        .test_cmd => |test_args| rocTest(gpa, test_args),
        .repl => rocRepl(gpa),
        .version => rocVersion(gpa),
        .docs => |docs_args| rocDocs(gpa, docs_args),
        .help => |help_message| stdout.writeAll(help_message),
        .licenses => stdout.writeAll(legalDetailsFileContent),
        .problem => |problem| {
            try switch (problem) {
                .missing_flag_value => |details| stderr.print("Error: no value was supplied for {s}\n", .{details.flag}),
                .unexpected_argument => |details| stderr.print("Error: roc {s} received an unexpected argument: `{s}`\n", .{ details.cmd, details.arg }),
                .invalid_flag_value => |details| stderr.print("Error: `{s}` is not a valid value for {s}. The valid options are {s}\n", .{ details.value, details.flag, details.valid_options }),
            };
            std.process.exit(1);
        },
    };
}

fn rocRun(gpa: Allocator, args: cli_args.RunArgs) void {
    _ = gpa;
    _ = args;
    fatal("run not implemented", .{});
}

fn rocBuild(gpa: Allocator, args: cli_args.BuildArgs) void {
    _ = gpa;
    _ = args;

    fatal("build not implemented", .{});
}

fn rocTest(gpa: Allocator, args: cli_args.TestArgs) !void {
    _ = gpa;
    _ = args;
    fatal("test not implemented", .{});
}

fn rocRepl(gpa: Allocator) !void {
    _ = gpa;
    fatal("repl not implemented", .{});
}

/// Reads, parses, formats, and overwrites all Roc files at the given paths.
/// Recurses into directories to search for Roc files.
fn rocFormat(gpa: Allocator, arena: Allocator, args: cli_args.FormatArgs) !void {
    var timer = try std.time.Timer.start();
    var count = fmt.SuccessFailCount{ .success = 0, .failure = 0 };
    for (args.paths) |path| {
        const inner_count = try fmt.formatPath(gpa, arena, std.fs.cwd(), path);
        count.success += inner_count.success;
        count.failure += inner_count.failure;
    }
    const elapsed = timer.read() / std.time.ns_per_ms;
    try std.io.getStdOut().writer().print("Successfully formatted {} files\n", .{count.success});
    if (count.failure > 0) {
        try std.io.getStdOut().writer().print("Failed to format {} files.\n", .{count.failure});
    }
    try std.io.getStdOut().writer().print("Took {} ms.\n", .{elapsed});
}

fn rocVersion(gpa: Allocator) !void {
    _ = gpa;
    fatal("version not implemented", .{});
}

fn rocCheck(gpa: Allocator, args: cli_args.CheckArgs) void {
    switch (coordinate.typecheckModule(gpa, Filesystem.default(), args.path)) {
        .success => |data| {
            var problems = std.ArrayList(Problem).init(gpa);
            var index_iter = data.can_irs.iterIndices();
            while (index_iter.next()) |idx| {
                const env = data.can_irs.getWork(idx).env;
                problems.appendSlice(env.problems.items.items) catch |err| exitOnOom(err);
            }

            for (problems.items) |problem| {
                std.debug.print("{}\n", .{problem});
            }

            std.debug.print("{} problems found.\n", .{problems.items.len});
        },
        .err => |err| {
            std.debug.print("Failed to check {s}:\n{}\n", .{ args.path, err });
        },
    }
}

fn rocDocs(gpa: Allocator, args: cli_args.DocsArgs) !void {
    _ = gpa;
    _ = args;
    fatal("docs not implemented", .{});
}
