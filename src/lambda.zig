//! zig [lambda runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html)
//!
//! A library for building zig aws lambda functions
const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.lambda);

/// Per-request context data. An instance of this is passed to every lambda invocation
pub const Context = struct {
    request_id: []const u8,
    deadline_ms: u64 = 0,
    invoked_function_arn: []const u8 = "unknown",
    trace_id: []const u8 = "unknown",

    pub fn remainingTimeMs(self: Context) i64 {
        return @as(i64, @intCast(self.deadline_ms)) - std.time.milliTimestamp();
    }
};

/// The type of a lambda function handler
pub fn Handler(
    comptime Ctx: type,
    comptime handleFn: fn (context: Ctx, std.mem.Allocator, ctx: Context, event: []const u8) anyerror![]const u8,
) type {
    return struct {
        context: Ctx,
        pub fn handle(self: *@This(), allocator: std.mem.Allocator, ctx: Context, event: []const u8) anyerror![]const u8 {
            return handleFn(self.context, allocator, ctx, event);
        }
    };
}

/// Wraps a free standing const fn handler in a type which implements the Handle interface.
pub fn wrap(f: *const fn (std.mem.Allocator, Context, []const u8) anyerror![]const u8) Wrap() {
    return .{ .f = f };
}

/// A type which is intended to wrap a const fn handler function
pub fn Wrap() type {
    return struct {
        f: *const fn (std.mem.Allocator, Context, []const u8) anyerror![]const u8,
        const Self = @This();
        pub const Wrapped = Handler(*Self, handle);
        pub fn handler(self: *Self) Wrapped {
            return .{ .context = self };
        }

        pub fn handle(self: *Self, allocator: std.mem.Allocator, ctx: Context, event: []const u8) anyerror![]const u8 {
            return self.f(allocator, ctx, event);
        }
    };
}

/// Helper to get environment variable as a slice
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// Creates a new runtime and drives lambda event loop.
pub fn run(allocator: ?std.mem.Allocator, handler_instance: anytype) !void {
    log.info("starting runtime", .{});
    const alloc = allocator orelse std.heap.smp_allocator;
    const runtime_api = getenv("AWS_LAMBDA_RUNTIME_API") orelse return error.MissingLambdaEnv;
    const uri = try std.fmt.allocPrint(alloc, "http://{s}/2018-06-01/runtime", .{runtime_api});
    defer alloc.free(uri);

    var hand = handler_instance;

    while (true) {
        const next_url = try std.fmt.allocPrint(alloc, "{s}/invocation/next", .{uri});
        defer alloc.free(next_url);

        var threaded: std.Io.Threaded = .init(alloc, .{});
        const io = threaded.io();

        var client: std.http.Client = .{ .allocator = alloc, .io = io };
        defer client.deinit();

        const next_uri = std.Uri.parse(next_url) catch return error.InvalidNextUri;
        var req = try client.request(.GET, next_uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        var header_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&header_buf);

        var request_id: ?[]const u8 = null;
        var invoked_function_arn: ?[]const u8 = null;
        var deadline_ms: u64 = 0;
        var trace_id: ?[]const u8 = null;

        var iter = response.head.iterateHeaders();
        while (iter.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase("Lambda-Runtime-Aws-Request-Id", hdr.name)) {
                request_id = hdr.value;
            } else if (std.ascii.eqlIgnoreCase("Lambda-Runtime-Deadline-Ms", hdr.name)) {
                deadline_ms = std.fmt.parseInt(u64, hdr.value, 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase("Lambda-Runtime-Invoked-Function-Arn", hdr.name)) {
                invoked_function_arn = hdr.value;
            } else if (std.ascii.eqlIgnoreCase("Lambda-Runtime-Trace-Id", hdr.name)) {
                trace_id = hdr.value;
            }
        }

        const rid = request_id orelse return error.MissingRequestId;
        const rid_owned = try alloc.dupe(u8, rid);
        defer alloc.free(rid_owned);

        var reader = response.reader(&.{});
        const body = try reader.allocRemaining(alloc, .unlimited);
        defer alloc.free(body);

        const ctx = Context{
            .request_id = rid_owned,
            .deadline_ms = deadline_ms,
            .invoked_function_arn = invoked_function_arn orelse "unknown",
            .trace_id = trace_id orelse "unknown",
        };

        log.debug("invoking handler", .{});
        const handler_response = hand.handle(alloc, ctx, body) catch |err| {
            log.warn("catching handler error {s}", .{@errorName(err)});
            reportError(alloc, uri, rid_owned, @errorReturnTrace(), err) catch |err2| {
                log.err("failed to report error {s}", .{@errorName(err2)});
            };
            continue;
        };

        sendResponse(alloc, uri, rid_owned, handler_response) catch |err| {
            log.err("failed to send response {s}", .{@errorName(err)});
            continue;
        };
    }
}

fn sendResponse(alloc: std.mem.Allocator, base_uri: []const u8, request_id: []const u8, payload: []const u8) !void {
    const url = try std.fmt.allocPrint(alloc, "{s}/invocation/{s}/response", .{ base_uri, request_id });
    defer alloc.free(url);

    var threaded: std.Io.Threaded = .init(alloc, .{});
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
    });
    log.debug("response complete", .{});
}

fn reportError(alloc: std.mem.Allocator, base_uri: []const u8, request_id: []const u8, trace: ?*std.builtin.StackTrace, caught: anytype) !void {
    const url = try std.fmt.allocPrint(alloc, "{s}/invocation/{s}/error", .{ base_uri, request_id });
    defer alloc.free(url);

    const body = if (trace != null)
        try std.fmt.allocPrint(alloc,
            \\{{
            \\  "errorMessage": "{s}",
            \\  "errorType": "Runtime.UnknownReason",
            \\  "stackTrace": ["todo"]
            \\}}
        , .{@errorName(caught)})
    else
        try std.fmt.allocPrint(alloc,
            \\{{
            \\  "errorMessage": "{s}",
            \\  "errorType": "Runtime.UnknownReason",
            \\  "stackTrace": []
            \\}}
        , .{@errorName(caught)});
    defer alloc.free(body);

    var threaded: std.Io.Threaded = .init(alloc, .{});
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "Lambda-Runtime-Function-Error-Type", .value = "Runtime.UnknownReason" },
        },
    });
    log.debug("error report complete", .{});
}

// --- Tests ---

test "wrapped handler" {
    const allocator = std.testing.allocator;
    var wrapped = wrap(demo);
    var handler_inst = wrapped.handler();
    try testing.expectEqualStrings("test", try handler_inst.handle(allocator, .{ .request_id = "123" }, "test"));
}

test "custom handler" {
    const Echo = struct {
        const Self = @This();
        const EchoHandler = Handler(*Self, handle);
        pub fn handler(self: *Self) EchoHandler {
            return .{ .context = self };
        }
        pub fn handle(self: *Self, allocator: std.mem.Allocator, ctx: Context, event: []const u8) anyerror![]const u8 {
            _ = self;
            _ = allocator;
            _ = ctx;
            return event;
        }
    };
    const allocator = std.testing.allocator;
    var custom = Echo{};
    var handler_inst = custom.handler();
    try testing.expectEqualStrings("test", try handler_inst.handle(allocator, .{ .request_id = "123" }, "test"));
}

fn demo(allocator: std.mem.Allocator, ctx: Context, event: []const u8) ![]const u8 {
    _ = allocator;
    _ = ctx;
    return event;
}
