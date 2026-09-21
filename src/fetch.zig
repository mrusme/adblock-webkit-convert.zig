const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnsupportedUrl,
    BadStatus,
    TooLarge,
    RequestFailed,
    UnsupportedEncoding,
    Timeout,
    Canceled,
    OutOfMemory,
};

pub const Options = struct {
    user_agent: []const u8,
    /// Attempts in total.
    attempts: u8 = 3,
    /// Wait after first failure, each further wait doubles.
    backoff: std.Io.Duration = .fromSeconds(1),
    max_bytes: usize = 32 << 20,
    timeout: std.Io.Timeout = .none,
};

/// Reads a filter list, the caller owns the result.
pub fn download(
    gpa: Allocator,
    io: std.Io,
    url: []const u8,
    options: Options,
) Error![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const deadline = options.timeout.toDeadline(io);

    var attempt: u8 = 0;
    var wait = options.backoff;
    while (true) {
        attempt += 1;
        return bounded(gpa, io, &client, url, options, deadline) catch |err| {
            const retryable = err == error.RequestFailed;
            if (!retryable or attempt >= options.attempts) return err;

            var pause = wait;
            if (deadline.toDurationFromNow(io)) |remaining| {
                if (remaining.raw.nanoseconds <= 0) return error.Timeout;
                if (remaining.raw.nanoseconds < pause.nanoseconds) {
                    pause = .{ .nanoseconds = remaining.raw.nanoseconds };
                }
            }

            io.sleep(pause, .awake) catch return error.Canceled;
            wait = .{ .nanoseconds = wait.nanoseconds *| 2 };
            continue;
        };
    }
}

const Attempt = union(enum) {
    fetched: Error![]u8,
    expired: void,
};

fn bounded(
    gpa: Allocator,
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    options: Options,
    deadline: std.Io.Timeout,
) Error![]u8 {
    if (deadline == .none) return once(gpa, client, url, options);

    var slots: [2]Attempt = undefined;
    var race: std.Io.Select(Attempt) = .init(io, &slots);

    race.concurrent(.expired, expire, .{ io, deadline }) catch
        return once(gpa, client, url, options);

    race.concurrent(.fetched, once, .{ gpa, client, url, options }) catch {
        drain(gpa, &race);
        return once(gpa, client, url, options);
    };

    const first = race.await() catch {
        drain(gpa, &race);
        return error.Canceled;
    };
    defer drain(gpa, &race);

    return switch (first) {
        .fetched => |fetched| fetched,
        .expired => error.Timeout,
    };
}

fn expire(io: std.Io, deadline: std.Io.Timeout) void {
    deadline.sleep(io) catch {};
}

fn drain(gpa: Allocator, race: *std.Io.Select(Attempt)) void {
    while (race.cancel()) |result| switch (result) {
        .fetched => |fetched| if (fetched) |body| gpa.free(body) else |_| {},
        .expired => {},
    };
}

fn once(
    gpa: Allocator,
    client: *std.http.Client,
    url: []const u8,
    options: Options,
) Error![]u8 {
    const uri = std.Uri.parse(url) catch return error.UnsupportedUrl;

    var request = client.request(.GET, uri, .{
        .extra_headers = &.{.{ .name = "user-agent", .value = options.user_agent }},
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.UnsupportedUriScheme, error.UriMissingHost => error.UnsupportedUrl,
        else => error.RequestFailed,
    };
    defer request.deinit();

    request.sendBodiless() catch return readFailure(&request);

    var redirect_buffer: [8 << 10]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch return readFailure(&request);
    if (response.head.status != .ok) return error.BadStatus;

    const window: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .zstd => std.compress.zstd.default_window_len,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .compress => return error.UnsupportedEncoding,
    };
    const decompress_buffer = try gpa.alloc(u8, window);
    defer gpa.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    return reader.allocRemaining(gpa, .limited(options.max_bytes)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        else => readFailure(&request),
    };
}

fn readFailure(request: *std.http.Client.Request) Error {
    const connection = request.connection orelse return error.RequestFailed;
    return switch (connection.stream_reader.err orelse return error.RequestFailed) {
        error.Canceled => error.Canceled,
        error.Timeout => error.Timeout,
        else => error.RequestFailed,
    };
}

const testing = std.testing;

fn listenLocally(port: *u16) !std.Io.net.Server {
    var candidate: u16 = 49731;
    while (candidate < 49771) : (candidate += 1) {
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", candidate) catch unreachable;
        const server = address.listen(testing.io, .{ .kernel_backlog = 8 }) catch continue;
        port.* = candidate;
        return server;
    }
    return error.NoFreePort;
}

test "a download gives up on a server that accepts and never answers" {
    var port: u16 = undefined;
    var server = try listenLocally(&port);
    defer server.deinit(testing.io);

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/list.txt", .{port});

    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Timeout, download(testing.allocator, testing.io, url, .{
        .user_agent = "test",
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } },
    }));

    const taken = started.durationTo(.now(testing.io, .awake));
    try testing.expect(taken.nanoseconds < std.Io.Duration.fromSeconds(10).nanoseconds);
}

test "the budget covers the waits between attempts, not only each attempt" {
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Timeout, download(testing.allocator, testing.io, "http://127.0.0.1:1/list.txt", .{
        .user_agent = "test",
        .backoff = .fromSeconds(30),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } },
    }));

    const taken = started.durationTo(.now(testing.io, .awake));
    try testing.expect(taken.nanoseconds < std.Io.Duration.fromSeconds(5).nanoseconds);
}

test "a scheme no client speaks is rejected before anything is opened" {
    try testing.expectError(error.UnsupportedUrl, download(testing.allocator, testing.io, "gopher://example.com/x", .{
        .user_agent = "test",
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }));
}
