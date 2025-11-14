const std = @import("std");

/// Compile Zig source code to native binary
pub fn compileZig(allocator: std.mem.Allocator, zig_code: []const u8, output_path: []const u8) !void {
    // Copy runtime files to /tmp for import
    const runtime_files = [_][]const u8{ "runtime.zig", "pystring.zig", "pylist.zig", "dict.zig", "pyint.zig", "pytuple.zig", "async.zig", "http.zig" };
    for (runtime_files) |file| {
        const src_path = try std.fmt.allocPrint(allocator, "packages/runtime/src/{s}", .{file});
        defer allocator.free(src_path);
        const dst_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{file});
        defer allocator.free(dst_path);

        const src = std.fs.cwd().openFile(src_path, .{}) catch continue;
        defer src.close();
        const dst = try std.fs.createFileAbsolute(dst_path, .{});
        defer dst.close();

        const content = try src.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        try dst.writeAll(content);
    }

    // Write Zig code to temporary file
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/pyx_main_{d}.zig", .{std.time.milliTimestamp()});
    defer allocator.free(tmp_path);

    // Write temp file
    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer tmp_file.close();
    // Keep for debugging - don't delete
    // defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try tmp_file.writeAll(zig_code);

    // Shell out to zig build-exe
    const zig_path = try findZigBinary(allocator);
    defer allocator.free(zig_path);

    const output_flag = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path});
    defer allocator.free(output_flag);

    // Get runtime path and add it to the module search path
    const runtime_path = try std.fs.cwd().realpathAlloc(allocator, "packages/runtime/src");
    defer allocator.free(runtime_path);

    const i_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{runtime_path});
    defer allocator.free(i_flag);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            zig_path,
            "build-exe",
            tmp_path,
            i_flag,
            "-ODebug",
            output_flag,
        },
    });
    // Child.run always allocates stdout/stderr, must free them
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Zig compilation failed:\n{s}\n", .{result.stderr});
        return error.ZigCompilationFailed;
    }
}

/// Compile Zig source code to shared library (.so/.dylib)
pub fn compileZigSharedLib(allocator: std.mem.Allocator, zig_code: []const u8, output_path: []const u8) !void {
    // Copy runtime files to /tmp for import
    const runtime_files = [_][]const u8{ "runtime.zig", "pystring.zig", "pylist.zig", "dict.zig", "pyint.zig", "pytuple.zig", "async.zig", "http.zig" };
    for (runtime_files) |file| {
        const src_path = try std.fmt.allocPrint(allocator, "packages/runtime/src/{s}", .{file});
        defer allocator.free(src_path);
        const dst_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{file});
        defer allocator.free(dst_path);

        const src = std.fs.cwd().openFile(src_path, .{}) catch continue;
        defer src.close();
        const dst = try std.fs.createFileAbsolute(dst_path, .{});
        defer dst.close();

        const content = try src.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        try dst.writeAll(content);
    }

    // Write Zig code to temporary file
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/pyx_main_{d}.zig", .{std.time.milliTimestamp()});
    defer allocator.free(tmp_path);

    // Write temp file
    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer tmp_file.close();

    try tmp_file.writeAll(zig_code);

    // Shell out to zig build-lib (shared library)
    const zig_path = try findZigBinary(allocator);
    defer allocator.free(zig_path);

    const output_flag = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path});
    defer allocator.free(output_flag);

    // Get runtime path and add it to the module search path
    const runtime_path = try std.fs.cwd().realpathAlloc(allocator, "packages/runtime/src");
    defer allocator.free(runtime_path);

    const i_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{runtime_path});
    defer allocator.free(i_flag);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            zig_path,
            "build-lib", // ← build-lib instead of build-exe
            tmp_path,
            i_flag,
            "-ODebug",
            "-dynamic", // ← Dynamic library (not static)
            output_flag,
        },
    });
    // Child.run always allocates stdout/stderr, must free them
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Zig compilation failed:\n{s}\n", .{result.stderr});
        return error.ZigCompilationFailed;
    }
}

fn findZigBinary(allocator: std.mem.Allocator) ![]const u8 {
    // Try to find zig in PATH
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "which", "zig" },
    }) catch {
        // Default to "zig" and hope it's in PATH
        return try allocator.dupe(u8, "zig");
    };
    // Child.run succeeded, must free stdout/stderr
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0) {
        const path = std.mem.trim(u8, result.stdout, " \n\r\t");
        return try allocator.dupe(u8, path);
    }

    return try allocator.dupe(u8, "zig");
}
