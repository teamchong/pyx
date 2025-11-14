const std = @import("std");
const runtime = @import("runtime.zig");

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }
};

/// HTTP GET request using Zig 0.15.2 Client API
pub fn get(allocator: std.mem.Allocator, url: []const u8) !HttpResponse {
    // Parse URL
    const uri = try std.Uri.parse(url);

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Create response buffer and writer
    var response_buf = std.ArrayList(u8){};
    errdefer response_buf.deinit(allocator);

    // Create proper Writer instance
    var buf_writer = response_buf.writer(allocator);
    var writer: std.io.Writer = buf_writer.writer();

    // Fetch request
    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &writer,
    });

    return HttpResponse{
        .status = @intFromEnum(result.status),
        .body = try response_buf.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Create PyString from HTTP response body
pub fn getAsPyString(allocator: std.mem.Allocator, url: []const u8) !*runtime.PyObject {
    var response = try get(allocator, url);
    defer response.deinit();

    return try runtime.PyString.create(allocator, response.body);
}

/// Create PyTuple of (status_code, body)
pub fn getAsResponse(allocator: std.mem.Allocator, url: []const u8) !*runtime.PyObject {
    var response = try get(allocator, url);
    defer response.deinit();

    // Create tuple: (status, body)
    const status_obj = try runtime.PyInt.create(allocator, @intCast(response.status));
    const body_obj = try runtime.PyString.create(allocator, response.body);

    const items = [_]*runtime.PyObject{ status_obj, body_obj };
    return try runtime.PyTuple.create(allocator, &items);
}
