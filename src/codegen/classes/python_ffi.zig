const std = @import("std");
const ast = @import("../../ast.zig");
const CodegenError = @import("../../codegen.zig").CodegenError;
const ExprResult = @import("../../codegen.zig").ExprResult;
const ZigCodeGenerator = @import("../../codegen.zig").ZigCodeGenerator;
const expressions = @import("../expressions.zig");

pub fn visitPythonFunctionCall(self: *ZigCodeGenerator, module_code: []const u8, func_name: []const u8, args: []ast.Node) CodegenError!ExprResult {
    self.needs_allocator = true;

    // Check for native JSON module calls (json.loads, json.dumps)
    const is_json_loads = std.mem.eql(u8, func_name, "loads");
    const is_json_dumps = std.mem.eql(u8, func_name, "dumps");

    if (is_json_loads or is_json_dumps) {
        // Native JSON handling
        if (args.len == 0) return error.MissingArgument;

        // Comptime optimization for constant JSON strings
        if (is_json_loads) {
            switch (args[0]) {
                .constant => |constant| {
                    if (constant.value == .string) {
                        // Generate cached JSON parse for constant strings
                        // This optimizes config files and constant JSON

                        // Get the JSON string content for deduplication
                        const json_str = constant.value.string;

                        // Check if we already have a cache for this exact JSON string
                        const cache_var = if (self.json_cache_map.get(json_str)) |existing_var|
                            existing_var
                        else blk: {
                            // First time seeing this JSON string - create new cache
                            const new_cache_var = try std.fmt.allocPrint(
                                self.allocator,
                                "_json_cache_{d}",
                                .{self.json_cache_counter}
                            );
                            self.json_cache_counter += 1;

                            // Store in map for future reuse
                            try self.json_cache_map.put(json_str, new_cache_var);

                            // Emit cache initialization at module level
                            var cache_buf = std.ArrayList(u8){};
                            try cache_buf.writer(self.temp_allocator).print(
                                "// Cached JSON parse for constant string\nvar {s}: ?*runtime.PyObject = null;",
                                .{new_cache_var}
                            );
                            try self.preamble.append(self.allocator, try cache_buf.toOwnedSlice(self.temp_allocator));

                            break :blk new_cache_var;
                        };

                        // Get the properly formatted Zig string code
                        const str_result = try expressions.visitExpr(self, args[0]);
                        const str_code = str_result.code;

                        // Generate cache check + parse code
                        var code_buf = std.ArrayList(u8){};
                        try code_buf.writer(self.temp_allocator).print(
                            "blk: {{ if ({s}) |cached| {{ runtime.incref(cached); break :blk cached; }} " ++
                            "const str = try {s}; " ++
                            "const parsed = try runtime.jsonLoads(str, allocator); " ++
                            "runtime.decref(str, allocator); " ++
                            "{s} = parsed; " ++
                            "runtime.incref(parsed); " ++
                            "break :blk parsed; }}",
                            .{ cache_var, str_code, cache_var }
                        );

                        const code = try code_buf.toOwnedSlice(self.temp_allocator);
                        return ExprResult{ .code = code, .needs_try = false, .needs_decref = true };
                    }
                },
                else => {},
            }
        }

        const arg_result = try expressions.visitExpr(self, args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);

        var buf = std.ArrayList(u8){};
        if (is_json_loads) {
            // json.loads(json_str) -> runtime.jsonLoads(json_str, allocator)
            try buf.writer(self.temp_allocator).print("runtime.jsonLoads({s}, allocator)", .{arg_code});
        } else {
            // json.dumps(obj) -> runtime.jsonDumps(obj, allocator)
            try buf.writer(self.temp_allocator).print("runtime.jsonDumps({s}, allocator)", .{arg_code});
        }

        const code = try buf.toOwnedSlice(self.temp_allocator);
        return ExprResult{ .code = code, .needs_try = true, .needs_decref = true };
    }

    // Check for native HTTP module calls (http.get)
    const is_http_get = std.mem.eql(u8, func_name, "get");

    if (is_http_get) {
        // Native HTTP handling
        if (args.len == 0) return error.MissingArgument;

        const arg_result = try expressions.visitExpr(self, args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);

        var buf = std.ArrayList(u8){};
        // http.get(url) -> runtime.httpGet(allocator, url)
        try buf.writer(self.temp_allocator).print("runtime.httpGet(allocator, {s})", .{arg_code});

        const code = try buf.toOwnedSlice(self.temp_allocator);
        return ExprResult{ .code = code, .needs_try = true, .needs_decref = true };
    }

    // Python package function call - use Zig C interop
    // Generate direct C function call to NumPy/Python C API

    // Build argument list
    var arg_codes = std.ArrayList([]const u8){};
    for (args) |arg| {
        const arg_result = try expressions.visitExpr(self, arg);
        const arg_code = try self.extractResultToStatement(arg_result);
        try arg_codes.append(self.temp_allocator, arg_code);
    }

    // Generate C function call
    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print(
        "// TODO: Direct C call to {s}.{s}(",
        .{ module_code, func_name }
    );

    for (arg_codes.items, 0..) |arg_code, i| {
        if (i > 0) try buf.writer(self.temp_allocator).writeAll(", ");
        try buf.writer(self.temp_allocator).writeAll(arg_code);
    }

    try buf.writer(self.temp_allocator).writeAll(")");

    const code = try buf.toOwnedSlice(self.temp_allocator);
    return ExprResult{ .code = code, .needs_try = false, .needs_decref = false };
}

/// Convert Zig value to Python object (*anyopaque)
fn convertToPythonObject(self: *ZigCodeGenerator, node: ast.Node, result: ExprResult, code: []const u8) CodegenError![]const u8 {
    _ = result; // May use this later for type info

    var buf = std.ArrayList(u8){};

    // Check if it's a constant that needs conversion
    switch (node) {
        .constant => |c| {
            switch (c.value) {
                .string => {
                    // String literal - code is already "runtime.PyString.create(...)"
                    // Just wrap in try since it returns !*PyObject
                    try buf.writer(self.temp_allocator).print("try {s}", .{code});
                    return try buf.toOwnedSlice(self.temp_allocator);
                },
                .int => |num| {
                    // Integer literal - convert to Python int
                    try buf.writer(self.temp_allocator).print("try python.fromInt({d})", .{num});
                    return try buf.toOwnedSlice(self.temp_allocator);
                },
                .float => |f| {
                    // Float literal - convert to Python float
                    try buf.writer(self.temp_allocator).print("try python.fromFloat({d})", .{f});
                    return try buf.toOwnedSlice(self.temp_allocator);
                },
                .bool => |b| {
                    // Bool literal - convert to Python bool (as int 0/1)
                    const val: i64 = if (b) 1 else 0;
                    try buf.writer(self.temp_allocator).print("try python.fromInt({d})", .{val});
                    return try buf.toOwnedSlice(self.temp_allocator);
                },
            }
        },
        .list => |list_node| {
            // List literal - for Python FFI, create a Python list, not PyAOT list
            // Check if all elements are integers
            var all_ints = true;
            var int_values = std.ArrayList(i64){};

            for (list_node.elts) |elt| {
                if (elt != .constant or elt.constant.value != .int) {
                    all_ints = false;
                    break;
                }
                try int_values.append(self.temp_allocator, elt.constant.value.int);
            }

            if (all_ints and int_values.items.len > 0) {
                // Create Python list from integers
                try buf.writer(self.temp_allocator).writeAll("try python.listFromInts(&[_]i64{");
                for (int_values.items, 0..) |val, i| {
                    if (i > 0) try buf.writer(self.temp_allocator).writeAll(", ");
                    try buf.writer(self.temp_allocator).print("{d}", .{val});
                }
                try buf.writer(self.temp_allocator).writeAll("})");
                return try buf.toOwnedSlice(self.temp_allocator);
            } else {
                // Fallback: use existing PyList code
                try buf.writer(self.temp_allocator).writeAll(code);
                return try buf.toOwnedSlice(self.temp_allocator);
            }
        },
        .name => {
            // Variable reference - check type to determine conversion
            const var_type = self.var_types.get(code);
            if (var_type) |vtype| {
                if (std.mem.eql(u8, vtype, "list")) {
                    // PyAOT list - convert to Python list for FFI
                    try buf.writer(self.temp_allocator).print("try python.convertPyListToPython({s})", .{code});
                    return try buf.toOwnedSlice(self.temp_allocator);
                } else if (std.mem.eql(u8, vtype, "string") or
                    std.mem.eql(u8, vtype, "dict") or
                    std.mem.eql(u8, vtype, "pyobject")) {
                    // Already a PyObject type (but not list)
                    try buf.writer(self.temp_allocator).writeAll(code);
                    return try buf.toOwnedSlice(self.temp_allocator);
                } else {
                    // Primitive type (i64, f64, bool) - convert
                    try buf.writer(self.temp_allocator).print("try python.fromInt({s})", .{code});
                    return try buf.toOwnedSlice(self.temp_allocator);
                }
            }
            // Unknown type, assume it's already suitable
            try buf.writer(self.temp_allocator).writeAll(code);
            return try buf.toOwnedSlice(self.temp_allocator);
        },
        else => {
            // Other expressions - assume they're already PyObjects
            try buf.writer(self.temp_allocator).writeAll(code);
            return try buf.toOwnedSlice(self.temp_allocator);
        },
    }
}
