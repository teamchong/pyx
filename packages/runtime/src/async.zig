const std = @import("std");

/// Async sleep (yields to event loop)
pub fn sleep(seconds: f64) void {
    const nanos = @as(u64, @intFromFloat(seconds * 1_000_000_000));
    std.Thread.sleep(nanos);
}

/// Async sleep returning when done
pub fn sleepAsync(seconds: f64) !void {
    sleep(seconds);
}

/// Get current timestamp (for benchmarks)
pub fn now() f64 {
    const ns = std.time.nanoTimestamp();
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}
