const std = @import("std");
const adblock = @import("adblock_webkit_convert");

const Allocator = std.mem.Allocator;

const version = @import("build_options").version;

const usage =
    \\Usage: adblock-webkit-convert [options] <source> <target> [<source> <target> ...]
    \\
    \\Converts Adblock and uBlock Origin filter lists into the WebKit content 
    \\blocker JSON that Safari and WebKitGTK read. A source is a URL, which is 
    \\downloaded, or a path to a filter list. A target is a path, or - for 
    \\standard output.
    \\
    \\Options:
    \\  --max-age <hours>   Leave target alone while it is newer than this
    \\  --max-rules <n>     Rules per output file, 0 for one file however long
    \\  --keep-duplicates   Write rules that repeat one already written
    \\  --quiet             Report only what failed
    \\  -h, --help          Print this help and exit
    \\  -v, --version       Print the version and exit
    \\
    \\WebKit rejects a rule list past its own limit, which is why the default
    \\splits at 150000 rules. The parts after the first get -2, -3 and so on in
    \\front of the extension.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const err_out = &stderr.interface;
    defer err_out.flush() catch {};

    var stdout_buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var options: adblock.Options = .{ .user_agent = "adblock-webkit-convert/" ++ version };
    var quiet = false;

    var mappings: std.ArrayList(adblock.Mapping) = .empty;
    defer mappings.deinit(gpa);

    var pending: ?[]const u8 = null;

    // Arguments are copied rather than borrowed. On Windows iterator hands back
    // a slice of its own buffer, which next argument overwrites. These have to
    // last until the conversion runs.
    const argv = try collectArgs(gpa, init.arena.allocator(), init.minimal.args);
    defer gpa.free(argv);

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return 0;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try out.print("adblock-webkit-convert {s}\n", .{version});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep-duplicates")) {
            options.deduplicate = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-age")) {
            index += 1;
            if (index == argv.len) return fail(err_out, "--max-age needs a number of hours");
            const hours = std.fmt.parseInt(u32, argv[index], 10) catch
                return fail(err_out, "--max-age needs a number of hours");
            options.max_age = .fromSeconds(@as(i64, hours) * 3600);
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-rules")) {
            index += 1;
            if (index == argv.len) return fail(err_out, "--max-rules needs a number");
            options.max_rules_per_file = std.fmt.parseInt(usize, argv[index], 10) catch
                return fail(err_out, "--max-rules needs a number");
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            try err_out.print("unknown option {s}\n", .{arg});
            return 2;
        }

        const source = pending orelse {
            pending = arg;
            continue;
        };
        pending = null;
        try mappings.append(gpa, .{
            .source = if (isUrl(source)) .{ .url = source } else .{ .file = source },
            .target = if (std.mem.eql(u8, arg, "-")) .buffer else .{ .file = arg },
        });
    }

    if (pending != null) return fail(err_out, "every source needs a target after it");
    if (mappings.items.len == 0) {
        try out.writeAll(usage);
        return 2;
    }

    var report = try adblock.convertAll(gpa, init.io, mappings.items, options);
    defer report.deinit();

    for (mappings.items, report.results) |mapping, result| {
        switch (result.outcome) {
            .failed => {
                const failure = result.failure.?;
                try err_out.print("{s}: {s} failed: {t}\n", .{
                    mapping.label(), failure.stage.text(), failure.err,
                });
            },
            .fresh => if (!quiet) try err_out.print("{s}: already up to date\n", .{mapping.label()}),
            .converted => {
                for (result.buffers) |part| try out.writeAll(part);
                if (!quiet) try report_stats(err_out, mapping, result);
            },
        }
        try err_out.flush();
        try out.flush();
    }

    return if (report.ok()) 0 else 1;
}

fn report_stats(
    out: *std.Io.Writer,
    mapping: adblock.Mapping,
    result: adblock.Result,
) std.Io.Writer.Error!void {
    try out.print("{s}: {d} rules from {d} lines", .{
        mapping.label(),
        result.stats.rules,
        result.stats.lines,
    });
    if (result.stats.duplicates > 0) try out.print(", {d} repeated", .{result.stats.duplicates});
    if (result.files.len > 1) try out.print(", in {d} parts", .{result.files.len});
    try out.writeAll("\n");

    const skipped = result.stats.skippedTotal();
    if (skipped == 0) return;

    try out.print("  {d} filters have no WebKit equivalent:", .{skipped});
    var first = true;
    for (std.enums.values(adblock.SkipReason)) |reason| {
        const count = result.stats.skips(reason);
        if (count == 0) continue;
        try out.print("{s} {d} {s}", .{ if (first) "" else ",", count, reason.text() });
        first = false;
    }
    try out.writeAll("\n");
}

fn collectArgs(
    gpa: Allocator,
    arena: Allocator,
    args: std.process.Args,
) ![]const []const u8 {
    var collected: std.ArrayList([]const u8) = .empty;
    errdefer collected.deinit(gpa);

    var iterator = try args.iterateAllocator(gpa);
    defer iterator.deinit();

    _ = iterator.skip();
    while (iterator.next()) |arg| try collected.append(gpa, try arena.dupe(u8, arg));

    return try collected.toOwnedSlice(gpa);
}

fn fail(out: *std.Io.Writer, message: []const u8) !u8 {
    try out.print("{s}\n", .{message});
    return 2;
}

fn isUrl(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "http://") or std.mem.startsWith(u8, text, "https://");
}
