const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const compiler = @import("compiler.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "build") or std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing input file\n", .{});
            try printUsage();
            return;
        }

        const input_file = args[2];
        const output_file = if (args.len > 3) args[3] else null;

        try compileFile(allocator, input_file, output_file, command);
    } else if (std.mem.eql(u8, command, "test")) {
        // Run pytest for now (bridge to Python)
        std.debug.print("Running tests (bridge to Python)...\n", .{});
        _ = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "pytest", "-v" },
        });
    } else {
        // Default: treat first arg as file to run
        try compileFile(allocator, command, null, "run");
    }
}

fn compileFile(allocator: std.mem.Allocator, input_path: []const u8, output_path: ?[]const u8, mode: []const u8) !void {
    // Read source file
    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(source);

    // Determine output path
    const bin_path_allocated = output_path == null;
    const bin_path = output_path orelse blk: {
        const basename = std.fs.path.basename(input_path);
        const name_no_ext = if (std.mem.lastIndexOf(u8, basename, ".")) |idx|
            basename[0..idx]
        else
            basename;

        // Create .zyth/ directory if it doesn't exist
        std.fs.cwd().makeDir(".zyth") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const path = try std.fmt.allocPrint(allocator, ".zyth/{s}", .{name_no_ext});
        break :blk path;
    };
    defer if (bin_path_allocated) allocator.free(bin_path);

    // Check if binary is up-to-date using content hash
    const should_compile = try shouldRecompile(allocator, source, bin_path);

    if (!should_compile) {
        // Binary is up-to-date, skip compilation
        if (std.mem.eql(u8, mode, "run")) {
            // Just run the existing binary
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{bin_path},
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        } else {
            std.debug.print("✓ Binary up-to-date: {s}\n", .{bin_path});
        }
        return;
    }

    // PHASE 1: Lexer - Tokenize source code
    std.debug.print("Lexing...\n", .{});
    var lex = try lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    // PHASE 2: Parser - Build AST
    std.debug.print("Parsing...\n", .{});
    var p = parser.Parser.init(allocator, tokens);
    var tree = try p.parse();
    defer tree.deinit(allocator);

    // PHASE 3: Codegen - Generate Zig code
    std.debug.print("Generating Zig code...\n", .{});
    const zig_code = try codegen.generate(allocator, tree);
    defer allocator.free(zig_code);

    // Compile Zig code to binary
    std.debug.print("Compiling to binary...\n", .{});
    try compiler.compileZig(allocator, zig_code, bin_path);

    std.debug.print("✓ Compiled successfully to: {s}\n", .{bin_path});

    // Update cache with new hash
    try updateCache(allocator, source, bin_path);

    // Run if mode is "run"
    if (std.mem.eql(u8, mode, "run")) {
        std.debug.print("\n", .{});
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{bin_path},
        });
        // Free stdout/stderr from subprocess
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
}

fn printUsage() !void {
    std.debug.print(
        \\Usage:
        \\  zyth <file.py>              # Compile and run
        \\  zyth build <file.py>        # Compile only
        \\  zyth build <file.py> <out>  # Compile to specific path
        \\  zyth test                   # Run test suite
        \\
    , .{});
}

/// Compute SHA256 hash of source content
fn computeHash(source: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
    return hash;
}

/// Get cache file path for a binary
fn getCachePath(allocator: std.mem.Allocator, bin_path: []const u8) ![]const u8 {
    // Cache file next to binary: .zyth/fibonacci.hash
    return try std.fmt.allocPrint(allocator, "{s}.hash", .{bin_path});
}

/// Check if recompilation is needed (compare source hash with cached hash)
fn shouldRecompile(allocator: std.mem.Allocator, source: []const u8, bin_path: []const u8) !bool {
    // Check if binary exists
    std.fs.cwd().access(bin_path, .{}) catch return true; // Binary missing, must compile

    // Compute current source hash
    const current_hash = computeHash(source);

    // Read cached hash
    const cache_path = try getCachePath(allocator, bin_path);
    defer allocator.free(cache_path);

    const cached_hash_hex = std.fs.cwd().readFileAlloc(allocator, cache_path, 1024) catch {
        return true; // Cache missing, must compile
    };
    defer allocator.free(cached_hash_hex);

    // Convert hex string back to bytes
    if (cached_hash_hex.len != 64) return true; // Invalid cache

    var cached_hash: [32]u8 = undefined;
    for (0..32) |i| {
        cached_hash[i] = std.fmt.parseInt(u8, cached_hash_hex[i * 2 .. i * 2 + 2], 16) catch return true;
    }

    // Compare hashes
    return !std.mem.eql(u8, &current_hash, &cached_hash);
}

/// Update cache with new source hash
fn updateCache(allocator: std.mem.Allocator, source: []const u8, bin_path: []const u8) !void {
    const hash = computeHash(source);

    // Convert hash to hex string (manually)
    var hex_buf: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    // Write to cache file
    const cache_path = try getCachePath(allocator, bin_path);
    defer allocator.free(cache_path);

    const file = try std.fs.cwd().createFile(cache_path, .{});
    defer file.close();

    try file.writeAll(&hex_buf);
}
