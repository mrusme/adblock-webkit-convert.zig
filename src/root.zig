const std = @import("std");

const convert = @import("convert.zig");
const emit = @import("emit.zig");
const fetch = @import("fetch.zig");
const parse = @import("parse.zig");

const Allocator = std.mem.Allocator;

pub const SkipReason = parse.SkipReason;
pub const ResourceType = parse.ResourceType;
pub const Action = convert.Action;
pub const LoadType = convert.LoadType;
pub const Rule = convert.Rule;

pub const Source = union(enum) {
    buffer: []const u8,
    file: []const u8,
    url: []const u8,
};

pub const Target = union(enum) {
    buffer,
    /// Written to this path, directory has to exist. Write is atomic.
    file: []const u8,
};

pub const Mapping = struct {
    source: Source,
    target: Target,
    /// Used in messages. Defaults to the target's base name, or the source.
    name: ?[]const u8 = null,

    pub fn label(self: Mapping) []const u8 {
        if (self.name) |name| return name;
        return switch (self.target) {
            .file => |path| std.fs.path.basename(path),
            .buffer => switch (self.source) {
                .url => |url| url,
                .file => |path| std.fs.path.basename(path),
                .buffer => "buffer",
            },
        };
    }
};

pub const Options = struct {
    /// A file target newer than this is left alone, its mapping reports
    /// `.fresh`. Null converts every mapping, buffer targets ignore it.
    max_age: ?std.Io.Duration = null,
    /// WebKit rejects a rule list past its own cap. A list longer than this
    /// is written as several files. 0 turns splitting off.
    max_rules_per_file: usize = 150_000,
    deduplicate: bool = true,
    user_agent: []const u8 = "adblock-webkit-convert/0.1",
    /// Attempts per download, counting the first.
    attempts: u8 = 3,
    /// Largest filter list accepted, in bytes.
    max_source_bytes: usize = 32 << 20,
    on_progress: ?*const fn (context: ?*anyopaque, index: usize, result: *const Result) void = null,
    context: ?*anyopaque = null,
};

pub const Outcome = enum {
    /// List was read and its JSON written.
    converted,
    /// Target is newer than `max_age`, so nothing was read or written.
    fresh,
    /// Nothing was written, see `Result.failure`.
    failed,
};

pub const Stage = enum {
    download,
    read,
    write,

    pub fn text(self: Stage) []const u8 {
        return switch (self) {
            .download => "downloading",
            .read => "reading",
            .write => "writing",
        };
    }
};

pub const Failure = struct {
    stage: Stage,
    err: anyerror,
};

pub const Stats = struct {
    source_bytes: usize = 0,
    lines: usize = 0,
    comments: usize = 0,
    network: usize = 0,
    exceptions: usize = 0,
    cosmetic: usize = 0,
    /// Rules written, after deduplication.
    rules: usize = 0,
    /// Rules dropped as repeats of one already emitted.
    duplicates: usize = 0,
    skipped: [reason_count]usize = @splat(0),

    const reason_count = @typeInfo(SkipReason).@"enum".fields.len;

    pub fn skips(self: Stats, reason: SkipReason) usize {
        return self.skipped[@intFromEnum(reason)];
    }

    pub fn skippedTotal(self: Stats) usize {
        var total: usize = 0;
        for (self.skipped) |count| total += count;
        return total;
    }
};

pub const Result = struct {
    outcome: Outcome,
    failure: ?Failure = null,
    /// Paths written, first being the mapping's own target. Empty unless
    /// the outcome is `.converted` and the target is a file.
    files: []const []const u8 = &.{},
    /// One entry per part. Empty unless the target is a buffer.
    buffers: []const []const u8 = &.{},
    stats: Stats = .{},
};

pub const Report = struct {
    arena: *std.heap.ArenaAllocator,
    /// `results[i]` belongs to `mappings[i]`
    results: []Result,

    pub fn deinit(self: Report) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn ok(self: Report) bool {
        for (self.results) |result| {
            if (result.outcome == .failed) return false;
        }
        return true;
    }
};

pub fn convertAll(
    gpa: Allocator,
    io: std.Io,
    mappings: []const Mapping,
    options: Options,
) Allocator.Error!Report {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const results = try arena.allocator().alloc(Result, mappings.len);
    for (results) |*result| result.* = .{ .outcome = .failed };

    for (mappings, results, 0..) |mapping, *result, index| {
        try one(gpa, io, arena.allocator(), mapping, options, result);
        if (options.on_progress) |report| report(options.context, index, result);
    }

    return .{ .arena = arena, .results = results };
}

pub fn convertOne(
    gpa: Allocator,
    io: std.Io,
    mapping: Mapping,
    options: Options,
) Allocator.Error!Report {
    return convertAll(gpa, io, &.{mapping}, options);
}

fn one(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    mapping: Mapping,
    options: Options,
    result: *Result,
) Allocator.Error!void {
    if (mapping.target == .file and options.max_age != null) {
        if (isFresh(io, mapping.target.file, options.max_age.?)) {
            result.* = .{ .outcome = .fresh };
            return;
        }
    }

    var owned: ?[]u8 = null;
    defer if (owned) |text| gpa.free(text);

    const source: []const u8 = switch (mapping.source) {
        .buffer => |text| text,
        .file => |path| blk: {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(options.max_source_bytes)) catch |err| {
                result.* = .{ .outcome = .failed, .failure = .{ .stage = .read, .err = err } };
                return;
            };
            owned = text;
            break :blk text;
        },
        .url => |url| blk: {
            const text = fetch.download(gpa, io, url, .{
                .user_agent = options.user_agent,
                .attempts = options.attempts,
                .max_bytes = options.max_source_bytes,
            }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                result.* = .{ .outcome = .failed, .failure = .{ .stage = .download, .err = err } };
                return;
            };
            owned = text;
            break :blk text;
        },
    };

    var rules_arena: std.heap.ArenaAllocator = .init(gpa);
    defer rules_arena.deinit();

    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(gpa);

    var stats: Stats = .{ .source_bytes = source.len };
    try build(gpa, rules_arena.allocator(), source, &rules, &stats);

    if (options.deduplicate) stats.duplicates = try emit.deduplicate(gpa, &rules);
    stats.rules = rules.items.len;

    result.* = .{ .outcome = .converted, .stats = stats };
    switch (mapping.target) {
        .buffer => result.buffers = try toBuffers(arena, rules.items, options),
        .file => |path| result.files = toFiles(io, arena, path, rules.items, options) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            result.* = .{ .outcome = .failed, .failure = .{ .stage = .write, .err = err }, .stats = stats };
            return;
        },
    }
}

fn build(
    gpa: Allocator,
    arena: Allocator,
    source: []const u8,
    rules: *std.ArrayList(Rule),
    stats: *Stats,
) Allocator.Error!void {
    var parser: parse.Parser = .{ .gpa = gpa };
    defer parser.deinit();

    var converter: convert.Converter = .init(gpa, arena);
    defer converter.deinit();

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        stats.lines += 1;

        const filter = try parser.line(line);
        switch (filter.kind) {
            .comment => stats.comments += 1,
            .network => stats.network += 1,
            .exception => stats.exceptions += 1,
            .cosmetic => stats.cosmetic += 1,
            .unsupported => {},
        }

        if (try converter.filter(filter, rules)) |reason| {
            stats.skipped[@intFromEnum(reason)] += 1;
        }
    }
}

fn partCount(total: usize, max_per_file: usize) usize {
    if (max_per_file == 0 or total <= max_per_file) return 1;
    return (total + max_per_file - 1) / max_per_file;
}

fn partRules(rules: []const Rule, index: usize, max_per_file: usize) []const Rule {
    if (max_per_file == 0) return rules;
    const start = index * max_per_file;
    const end = @min(start + max_per_file, rules.len);
    return rules[start..end];
}

const WriteError = Allocator.Error || std.Io.File.OpenError || std.Io.Writer.Error ||
    std.Io.File.Atomic.ReplaceError;

fn toBuffers(arena: Allocator, rules: []const Rule, options: Options) Allocator.Error![]const []const u8 {
    const count = partCount(rules.len, options.max_rules_per_file);
    const parts = try arena.alloc([]const u8, count);

    for (parts, 0..) |*part, index| {
        var out: std.Io.Writer.Allocating = .init(arena);
        // An allocating writer fails only when the allocation does.
        emit.write(&out.writer, partRules(rules, index, options.max_rules_per_file)) catch
            return error.OutOfMemory;
        part.* = out.written();
    }
    return parts;
}

fn toFiles(
    io: std.Io,
    arena: Allocator,
    path: []const u8,
    rules: []const Rule,
    options: Options,
) WriteError![]const []const u8 {
    const count = partCount(rules.len, options.max_rules_per_file);
    const paths = try arena.alloc([]const u8, count);

    for (paths, 0..) |*slot, index| {
        slot.* = try partPath(arena, path, index);
        try writeFile(io, slot.*, partRules(rules, index, options.max_rules_per_file));
    }

    // A run that produced fewer parts than the one before it needs clean up.
    var stale = count;
    while (true) : (stale += 1) {
        const extra = try partPath(arena, path, stale);
        std.Io.Dir.cwd().deleteFile(io, extra) catch break;
    }

    return paths;
}

fn writeFile(io: std.Io, path: []const u8, rules: []const Rule) WriteError!void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    var buffer: [64 << 10]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    try emit.write(&file_writer.interface, rules);
    try file_writer.interface.flush();

    try atomic.replace(io);
}

fn partPath(arena: Allocator, path: []const u8, index: usize) Allocator.Error![]const u8 {
    if (index == 0) return path;

    const extension = std.fs.path.extension(path);
    const stem = path[0 .. path.len - extension.len];
    return std.fmt.allocPrint(arena, "{s}-{d}{s}", .{ stem, index + 1, extension });
}

/// File dated in the future counts as fresh.
fn isFresh(io: std.Io, path: []const u8, max_age: std.Io.Duration) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    const age = stat.mtime.durationTo(std.Io.Clock.real.now(io));
    return age.nanoseconds < max_age.nanoseconds;
}

test {
    _ = @import("regex.zig");
    _ = @import("parse.zig");
    _ = @import("convert.zig");
    _ = @import("emit.zig");
    _ = @import("fetch.zig");
}

const testing = std.testing;

const sample_list =
    \\! Title: Example list
    \\[Adblock Plus 2.0]
    \\||ads.example.com^
    \\@@||safe.example.com/ads.js
    \\example.org##.ad-banner
    \\example.org##+js(nano-sib)
    \\/ad.js$redirect=noop.js
    \\
;

test "a buffer converts to a buffer" {
    var report = try convertOne(testing.allocator, testing.io, .{
        .source = .{ .buffer = sample_list },
        .target = .buffer,
    }, .{});
    defer report.deinit();

    const result = report.results[0];
    try testing.expectEqual(Outcome.converted, result.outcome);
    try testing.expectEqual(@as(usize, 1), result.buffers.len);

    // Two rules for the blocking filter, because its pattern ends in a
    // separator, one for the exception and one for the hiding filter.
    try testing.expectEqual(@as(usize, 4), result.stats.rules);
    try testing.expectEqual(@as(usize, 1), result.stats.network);
    try testing.expectEqual(@as(usize, 1), result.stats.exceptions);
    try testing.expectEqual(@as(usize, 1), result.stats.cosmetic);
    try testing.expectEqual(@as(usize, 3), result.stats.comments);
    try testing.expectEqual(@as(usize, 1), result.stats.skips(.scriptlet));
    try testing.expectEqual(@as(usize, 1), result.stats.skips(.unsupported_option));

    try testing.expect(std.mem.startsWith(u8, result.buffers[0], "[{\"trigger\""));
    try testing.expect(std.mem.endsWith(u8, result.buffers[0], "}]"));
}

test "a list past the cap is written as several parts" {
    var report = try convertOne(testing.allocator, testing.io, .{
        .source = .{ .buffer = sample_list },
        .target = .buffer,
    }, .{ .max_rules_per_file = 3 });
    defer report.deinit();

    const result = report.results[0];
    try testing.expectEqual(@as(usize, 2), result.buffers.len);
    try testing.expect(std.mem.count(u8, result.buffers[0], "\"trigger\"") == 3);
    try testing.expect(std.mem.count(u8, result.buffers[1], "\"trigger\"") == 1);
}

test "repeated filters converge on one rule" {
    var report = try convertOne(testing.allocator, testing.io, .{
        .source = .{ .buffer = "||ads.example.com/a\n||ads.example.com/a\n" },
        .target = .buffer,
    }, .{});
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.results[0].stats.rules);
    try testing.expectEqual(@as(usize, 1), report.results[0].stats.duplicates);
}

const TempPath = struct {
    dir: testing.TmpDir,
    buffer: [128]u8 = undefined,

    fn init() TempPath {
        return .{ .dir = testing.tmpDir(.{}) };
    }

    fn deinit(self: *TempPath) void {
        self.dir.cleanup();
    }

    fn path(self: *TempPath, name: []const u8) []const u8 {
        const sep = std.fs.path.sep_str;
        return std.fmt.bufPrint(&self.buffer, ".zig-cache" ++ sep ++ "tmp" ++ sep ++ "{s}" ++ sep ++ "{s}", .{
            self.dir.sub_path, name,
        }) catch unreachable;
    }
};

test "a file target is written and then left alone while it is fresh" {
    var temp: TempPath = .init();
    defer temp.deinit();
    const target = temp.path("easylist.json");

    {
        var report = try convertOne(testing.allocator, testing.io, .{
            .source = .{ .buffer = sample_list },
            .target = .{ .file = target },
        }, .{});
        defer report.deinit();

        try testing.expectEqual(Outcome.converted, report.results[0].outcome);
        try testing.expectEqual(@as(usize, 1), report.results[0].files.len);
        try testing.expectEqualStrings(target, report.results[0].files[0]);
    }

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, target, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.startsWith(u8, written, "[{"));

    {
        var report = try convertOne(testing.allocator, testing.io, .{
            .source = .{ .buffer = sample_list },
            .target = .{ .file = target },
        }, .{ .max_age = .fromSeconds(3600) });
        defer report.deinit();

        try testing.expectEqual(Outcome.fresh, report.results[0].outcome);
        try testing.expectEqual(@as(usize, 0), report.results[0].files.len);
    }
}

test "a missing target is converted however fresh the others are" {
    var temp: TempPath = .init();
    defer temp.deinit();

    var report = try convertOne(testing.allocator, testing.io, .{
        .source = .{ .buffer = sample_list },
        .target = .{ .file = temp.path("absent.json") },
    }, .{ .max_age = .fromSeconds(3600) });
    defer report.deinit();

    try testing.expectEqual(Outcome.converted, report.results[0].outcome);
}

test "parts left by a longer run are removed" {
    var temp: TempPath = .init();
    defer temp.deinit();
    const target = temp.path("split.json");

    {
        var report = try convertOne(testing.allocator, testing.io, .{
            .source = .{ .buffer = sample_list },
            .target = .{ .file = target },
        }, .{ .max_rules_per_file = 1 });
        defer report.deinit();
        try testing.expectEqual(@as(usize, 4), report.results[0].files.len);
    }

    var second = temp;
    const part_four = second.path("split-4.json");
    _ = try std.Io.Dir.cwd().statFile(testing.io, part_four, .{});

    {
        var report = try convertOne(testing.allocator, testing.io, .{
            .source = .{ .buffer = sample_list },
            .target = .{ .file = target },
        }, .{});
        defer report.deinit();
        try testing.expectEqual(@as(usize, 1), report.results[0].files.len);
    }

    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(testing.io, part_four, .{}),
    );
}

test "a source that cannot be read is reported and the run continues" {
    var temp: TempPath = .init();
    defer temp.deinit();

    var report = try convertAll(testing.allocator, testing.io, &.{
        .{ .source = .{ .file = temp.path("absent.txt") }, .target = .buffer },
        .{ .source = .{ .buffer = sample_list }, .target = .buffer },
    }, .{});
    defer report.deinit();

    try testing.expect(!report.ok());
    try testing.expectEqual(Outcome.failed, report.results[0].outcome);
    try testing.expectEqual(Stage.read, report.results[0].failure.?.stage);
    try testing.expectEqual(Outcome.converted, report.results[1].outcome);
}

test "a mapping names itself after its target" {
    const mapping: Mapping = .{
        .source = .{ .url = "https://example.com/easylist.txt" },
        .target = .{ .file = "/tmp/filters/easylist.json" },
    };
    try testing.expectEqualStrings("easylist.json", mapping.label());

    const named: Mapping = .{ .source = .{ .buffer = "" }, .target = .buffer, .name = "inline" };
    try testing.expectEqualStrings("inline", named.label());
}
