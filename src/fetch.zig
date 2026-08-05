const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnsupportedUrl,
    BadStatus,
    TooLarge,
    RequestFailed,
    UnsupportedEncoding,
    OutOfMemory,
};

pub const Options = struct {
    user_agent: []const u8,
    /// Attempts in total.
    attempts: u8 = 3,
    /// Wait after first failure, each further wait doubles.
    backoff: std.Io.Duration = .fromSeconds(1),
    max_bytes: usize = 32 << 20,
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

    var attempt: u8 = 0;
    var wait = options.backoff;
    while (true) {
        attempt += 1;
        return once(gpa, &client, url, options) catch |err| {
            const retryable = err == error.RequestFailed;
            if (!retryable or attempt >= options.attempts) return err;

            io.sleep(wait, .awake) catch return err;
            wait = .{ .nanoseconds = wait.nanoseconds *| 2 };
            continue;
        };
    }
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
        error.UnsupportedUriScheme, error.UriMissingHost => error.UnsupportedUrl,
        else => error.RequestFailed,
    };
    defer request.deinit();

    request.sendBodiless() catch return error.RequestFailed;

    var redirect_buffer: [8 << 10]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch return error.RequestFailed;
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
        else => error.RequestFailed,
    };
}
