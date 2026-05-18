# Migration Guide: Zig 0.12.0 → 0.16.0

This document describes the changes made to migrate `zig-lambda-runtime` from Zig 0.12.0 to 0.16.0.

## Summary of Changes

### build.zig.zon

| 0.12 | 0.16 |
|------|------|
| `.name = "lambda"` | `.name = .lambda` (enum literal) |
| `.paths = .{""}` | `.paths = .{""}` (unchanged) |
| (not required) | `.fingerprint = 0x...` (hex integer, required) |
| `minimum_zig_version = "0.12.0"` | `minimum_zig_version = "0.16.0"` |

> Note: On first build, omit `.fingerprint` and Zig will tell you the correct value to use.

### build.zig

| 0.12 | 0.16 |
|------|------|
| `b.createModule(...)` + `try b.modules.put(...)` | `b.addModule("name", .{...})` |
| `try std.fmt.allocPrint(b.allocator, ...)` for step names | Comptime string concatenation (`++`) |
| `.root_source_file` directly in addTest/addExecutable | `.root_module = b.createModule(.{ .root_source_file = ... })` |

### std.heap.GeneralPurposeAllocator

```zig
// 0.12
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// 0.16
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
```

### std.http.Client

The HTTP client API changed significantly. The `client.fetch()` convenience method was removed in favor of explicit request lifecycle management.

```zig
// 0.12 - fetch convenience
var client = std.http.Client{ .allocator = allocator };
_ = try client.fetch(.{
    .location = .{ .url = url },
    .payload = body,
});

// 0.16 - explicit request lifecycle
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();
const uri = std.Uri.parse(url) catch return error.InvalidUri;
var req = try client.open(.POST, uri, .{
    .server_header_buffer = &buf,
});
defer req.deinit();
req.transfer_encoding = .{ .content_length = body.len };
try req.send();
try req.writer().writeAll(body);
try req.finish();
try req.wait();
```

### std.Uri

```zig
// 0.12 - parse from formatted allocation
const uri = try std.Uri.parse(formatted_string);

// 0.16 - same API, but used directly with string (no FormattedUri wrapper needed)
const uri = std.Uri.parse(url) catch return error.InvalidUri;
```

### std.ArrayList

```zig
// 0.12
var payload = try std.ArrayList(u8).initCapacity(self.allocator, content_length);
defer payload.deinit();

// 0.16 - use reader().readAllAlloc() instead for HTTP body reading
const body = try req.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
```

### Reading HTTP response body

```zig
// 0.12 - manual buffer management
const content_length = @as(usize, @intCast(req.response.content_length.?));
var payload = try std.ArrayList(u8).initCapacity(self.allocator, content_length);
try payload.resize(content_length);
const data = try payload.toOwnedSlice();
_ = try req.readAll(data);

// 0.16 - use the reader directly
const body = try req.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
```

### Env.fromOs() error handling

```zig
// 0.12 - panics on missing env vars with .?
pub fn fromOs() !?Env {
    return .{
        .runtime_api = std.posix.getenv("AWS_LAMBDA_RUNTIME_API").?,
    };
}

// 0.16 - graceful handling with orelse
pub fn fromOs() ?Env {
    const runtime_api = std.posix.getenv("AWS_LAMBDA_RUNTIME_API") orelse return null;
    return .{ .runtime_api = runtime_api };
}
```

### Context.remaining_time_ms

```zig
// 0.12 - bug: called deadline_ms as function, wrong subtraction order
fn remaining_time_ms(self: *@This()) u64 {
    return std.time.milliTimestamp() - self.deadline_ms();
}

// 0.16 - fixed: correct field access, correct order, proper return type
pub fn remainingTimeMs(self: Context) i64 {
    return @as(i64, @intCast(self.deadline_ms)) - std.time.milliTimestamp();
}
```

## Bug Fixes Included

1. **`remaining_time_ms`** — Fixed calling `deadline_ms` as a function (it's a field) and corrected subtraction order.
2. **Undefined variables in header parsing** — Changed from `undefined` to nullable types (`?[]const u8`) with proper fallback handling.
3. **`Env.fromOs()` panic** — Replaced `.?` unwrap (panic on null) with `orelse return null` for graceful error handling.
4. **Inconsistent HTTP client usage** — Unified to create a new client per request (avoids the segfault documented in the original code).
5. **Response body reading** — Replaced manual ArrayList + readAll pattern with `reader().readAllAlloc()`.

## Architecture Changes

- Removed `FormattedUri` helper struct (no longer needed).
- Removed `std.http.Client` field from `Event` struct (client is now created per-request in `respond`/`reportError`).
- Removed `std.http.Client` field from `Runtime` and `EventIterator` (created fresh per `next()` call).
- Renamed `Event.response()` → `Event.respond()` and `Event.err()` → `Event.reportError()` for clarity.

## Version Bump

- Library version: `0.2.0` → `0.3.0`
- Minimum Zig version: `0.12.0` → `0.16.0`

## For Consumers

If you depend on this library, update your `build.zig.zon`:

```zig
.lambda = .{
    .url = "https://github.com/softprops/zig-lambda-runtime/archive/refs/tags/v0.3.0.tar.gz",
    .hash = "...", // omit first, zig will tell you the expected value
},
```

And ensure your `build.zig` uses:

```zig
const lambda = b.dependency("lambda", .{
    .target = target,
    .optimize = optimize,
}).module("lambda");
exe.root_module.addImport("lambda", lambda);
```
