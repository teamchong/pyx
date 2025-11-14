const std = @import("std");
const ast = @import("../ast.zig");
const CodegenError = @import("../codegen.zig").CodegenError;
const ExprResult = @import("../codegen.zig").ExprResult;
const ZigCodeGenerator = @import("../codegen.zig").ZigCodeGenerator;
const expressions = @import("expressions.zig");

pub fn visitPrintCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) {
        return ExprResult{
            .code = "std.debug.print(\"\\n\", .{})",
            .needs_try = false,
        };
    }

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};

    // Determine print format based on variable type
    switch (arg) {
        .name => |name| {
            const var_type = self.var_types.get(name.id);
            if (var_type) |vtype| {
                if (std.mem.eql(u8, vtype, "pyobject")) {
                    // PyObject - need to extract value based on type
                    // Emit if-else chain directly as statement (no semicolon needed)
                    var print_buf = std.ArrayList(u8){};
                    try print_buf.writer(self.temp_allocator).print(
                        "if ({s}.type_id == .int) {{ std.debug.print(\"{{}}\\n\", .{{runtime.PyInt.getValue({s})}}); }} " ++
                        "else if ({s}.type_id == .string) {{ std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue({s})}}); }} " ++
                        "else if ({s}.type_id == .list) {{ runtime.printList({s}); std.debug.print(\"\\n\", .{{}}); }} " ++
                        "else {{ std.debug.print(\"{{any}}\\n\", .{{{s}}}); }}",
                        .{ name.id, name.id, name.id, name.id, name.id, name.id, name.id }
                    );
                    try self.emitOwned(try print_buf.toOwnedSlice(self.temp_allocator));
                    // Return empty code since we already emitted the statement
                    return ExprResult{
                        .code = "",
                        .needs_try = false,
                    };
                } else if (std.mem.eql(u8, vtype, "string")) {
                    try buf.writer(self.temp_allocator).print("std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue({s})}})", .{arg_result.code});
                } else if (std.mem.eql(u8, vtype, "tuple")) {
                    // Emit tuple print as statement
                    var print_buf = std.ArrayList(u8){};
                    try print_buf.writer(self.temp_allocator).print("{{ runtime.PyTuple.print({s}); std.debug.print(\"\\n\", .{{}}); }}", .{arg_result.code});
                    try self.emitOwned(try print_buf.toOwnedSlice(self.temp_allocator));
                    return ExprResult{
                        .code = "",
                        .needs_try = false,
                    };
                } else {
                    try buf.writer(self.temp_allocator).print("std.debug.print(\"{{}}\\n\", .{{{s}}})", .{arg_result.code});
                }
            } else {
                try buf.writer(self.temp_allocator).print("std.debug.print(\"{{}}\\n\", .{{{s}}})", .{arg_result.code});
            }
        },
        .subscript => {
            // Subscript returns PyObject - may be error union or already unwrapped
            var print_buf = std.ArrayList(u8){};

            // Generate unique temp var name
            const temp_var = try std.fmt.allocPrint(self.allocator, "_print_tmp_{d}", .{@intFromPtr(arg_result.code.ptr)});

            // Use 'try' only if needed (list subscripts return error unions, dict subscripts don't)
            const unwrap = if (arg_result.needs_try) "try " else "";

            try print_buf.writer(self.temp_allocator).print(
                "{{ const {s} = {s}{s}; " ++
                "defer runtime.decref({s}, allocator); " ++
                "switch ({s}.type_id) {{ " ++
                ".int => std.debug.print(\"{{}}\\n\", .{{runtime.PyInt.getValue({s})}}), " ++
                ".string => std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue({s})}}), " ++
                ".list => {{ runtime.printList({s}); std.debug.print(\"\\n\", .{{}}); }}, " ++
                "else => std.debug.print(\"{{any}}\\n\", .{{{s}}}), " ++
                "}} }}",
                .{temp_var, unwrap, arg_result.code, temp_var, temp_var, temp_var, temp_var, temp_var, temp_var}
            );
            try self.emitOwned(try print_buf.toOwnedSlice(self.temp_allocator));
            return ExprResult{
                .code = "",
                .needs_try = false,
            };
        },
        .call => |call| {
            // Check if this is a function call that returns a primitive (like len, abs, etc.)
            const returns_primitive = blk: {
                switch (call.func.*) {
                    .name => |func_name| {
                        // Functions that return primitives, not PyObjects
                        const primitive_funcs = [_][]const u8{"len", "abs", "round", "min", "max", "sum"};
                        for (primitive_funcs) |pf| {
                            if (std.mem.eql(u8, func_name.id, pf)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    },
                    .attribute => |attr| {
                        // Some methods return primitives (count, index, find)
                        // Others return PyObjects (upper, strip, etc.)
                        const primitive_methods = [_][]const u8{"count", "index", "find"};
                        for (primitive_methods) |pm| {
                            if (std.mem.eql(u8, attr.attr, pm)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    },
                    else => break :blk false,
                }
            };

            if (returns_primitive) {
                // Regular primitive - just print it
                if (arg_result.needs_try) {
                    try buf.writer(self.temp_allocator).print("std.debug.print(\"{{}}\\n\", .{{try {s}}})", .{arg_result.code});
                } else {
                    try buf.writer(self.temp_allocator).print("std.debug.print(\"{{}}\\n\", .{{{s}}})", .{arg_result.code});
                }
            } else {
                // Method call - returns PyObject
                var print_buf = std.ArrayList(u8){};

                // Generate unique temp var name
                const temp_var = try std.fmt.allocPrint(self.allocator, "_print_tmp_{d}", .{@intFromPtr(arg_result.code.ptr)});

                // Use 'try' if needed
                const unwrap = if (arg_result.needs_try) "try " else "";

                try print_buf.writer(self.temp_allocator).print(
                    "{{ const {s} = {s}{s}; " ++
                    "defer runtime.decref({s}, allocator); " ++
                    "switch ({s}.type_id) {{ " ++
                    ".int => std.debug.print(\"{{}}\\n\", .{{runtime.PyInt.getValue({s})}}), " ++
                    ".string => std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue({s})}}), " ++
                    ".list => {{ runtime.printList({s}); std.debug.print(\"\\n\", .{{}}); }}, " ++
                    "else => std.debug.print(\"{{any}}\\n\", .{{{s}}}), " ++
                    "}} }}",
                    .{temp_var, unwrap, arg_result.code, temp_var, temp_var, temp_var, temp_var, temp_var, temp_var}
                );
                try self.emitOwned(try print_buf.toOwnedSlice(self.temp_allocator));
                return ExprResult{
                    .code = "",
                    .needs_try = false,
                };
            }
        },
        else => {
            // For string constants, extract raw string and use directly (no PyObject needed)
            const is_string_const = switch (arg) {
                .constant => |c| c.value == .string,
                else => false,
            };

            if (is_string_const) {
                // Extract string content from PyString.create() call
                // arg_result.code = runtime.PyString.create(allocator, "content")
                // We want just "content"
                const start_quote = std.mem.indexOf(u8, arg_result.code, "\"");
                if (start_quote) |start| {
                    const end_quote = std.mem.lastIndexOf(u8, arg_result.code, "\"");
                    if (end_quote) |end| {
                        const raw_string = arg_result.code[start..end + 1];
                        try buf.writer(self.temp_allocator).print("std.debug.print(\"{{s}}\\n\", .{{{s}}})", .{raw_string});
                    } else {
                        // Fallback if parsing fails
                        try buf.writer(self.temp_allocator).print("std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue(try {s})}})", .{arg_result.code});
                    }
                } else {
                    // Fallback if parsing fails
                    try buf.writer(self.temp_allocator).print("std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue(try {s})}})", .{arg_result.code});
                }
            } else if (arg_result.needs_try) {
                try buf.writer(self.temp_allocator).print("std.debug.print(\"{{}}\\n\", .{{try {s}}})", .{arg_result.code});
            } else {
                try buf.writer(self.temp_allocator).print("std.debug.print(\"{{}}\\n\", .{{{s}}})", .{arg_result.code});
            }
        },
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitLenCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};

    // Check variable type to determine which len() to call
    switch (arg) {
        .name => |name| {
            const var_type = self.var_types.get(name.id);
            if (var_type) |vtype| {
                if (std.mem.eql(u8, vtype, "list")) {
                    try buf.writer(self.temp_allocator).print("runtime.PyList.len({s})", .{arg_result.code});
                } else if (std.mem.eql(u8, vtype, "string")) {
                    try buf.writer(self.temp_allocator).print("runtime.PyString.len({s})", .{arg_result.code});
                } else if (std.mem.eql(u8, vtype, "dict")) {
                    try buf.writer(self.temp_allocator).print("runtime.PyDict.len({s})", .{arg_result.code});
                } else if (std.mem.eql(u8, vtype, "tuple")) {
                    try buf.writer(self.temp_allocator).print("runtime.PyTuple.len({s})", .{arg_result.code});
                } else {
                    try buf.writer(self.temp_allocator).print("runtime.PyList.len({s})", .{arg_result.code});
                }
            } else {
                try buf.writer(self.temp_allocator).print("runtime.PyList.len({s})", .{arg_result.code});
            }
        },
        else => {
            try buf.writer(self.temp_allocator).print("runtime.PyList.len({s})", .{arg_result.code});
        },
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitAbsCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("@abs({s})", .{arg_result.code});

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitRoundCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};
    // Python's round() returns an int, Zig's @round() returns same type
    // Cast to i64 to match Python behavior
    try buf.writer(self.temp_allocator).print("@as(i64, @intFromFloat(@round({s})))", .{arg_result.code});

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitMinCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    var buf = std.ArrayList(u8){};

    if (args.len == 1) {
        // min([1, 2, 3]) - list argument - needs runtime
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.temp_allocator).print("runtime.minList({s})", .{arg_result.code});
    } else if (args.len == 2) {
        // min(a, b) - use @min builtin
        const arg1 = try expressions.visitExpr(self,args[0]);
        const arg2 = try expressions.visitExpr(self,args[1]);
        try buf.writer(self.temp_allocator).print("@min({s}, {s})", .{ arg1.code, arg2.code });
    } else {
        // min(a, b, c, ...) - chain @min calls
        var result_code = try expressions.visitExpr(self,args[0]);
        for (args[1..]) |arg| {
            const arg_result = try expressions.visitExpr(self,arg);
            var temp_buf = std.ArrayList(u8){};
            try temp_buf.writer(self.temp_allocator).print("@min({s}, {s})", .{ result_code.code, arg_result.code });
            result_code.code = try temp_buf.toOwnedSlice(self.temp_allocator);
        }
        return result_code;
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitMaxCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    var buf = std.ArrayList(u8){};

    if (args.len == 1) {
        // max([1, 2, 3]) - list argument - needs runtime
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.temp_allocator).print("runtime.maxList({s})", .{arg_result.code});
    } else if (args.len == 2) {
        // max(a, b) - use @max builtin
        const arg1 = try expressions.visitExpr(self,args[0]);
        const arg2 = try expressions.visitExpr(self,args[1]);
        try buf.writer(self.temp_allocator).print("@max({s}, {s})", .{ arg1.code, arg2.code });
    } else {
        // max(a, b, c, ...) - chain @max calls
        var result_code = try expressions.visitExpr(self,args[0]);
        for (args[1..]) |arg| {
            const arg_result = try expressions.visitExpr(self,arg);
            var temp_buf = std.ArrayList(u8){};
            try temp_buf.writer(self.temp_allocator).print("@max({s}, {s})", .{ result_code.code, arg_result.code });
            result_code.code = try temp_buf.toOwnedSlice(self.temp_allocator);
        }
        return result_code;
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitSumCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("runtime.sum({s})", .{arg_result.code});

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitAllCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("runtime.all({s})", .{arg_result.code});

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitAnyCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingLenArg;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("runtime.any({s})", .{arg_result.code});

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

/// Handles Python's http_get() built-in
/// Returns tuple of (status_code, body) as PyObject
pub fn visitHttpGetCall(self: *ZigCodeGenerator, args: []ast.Node) CodegenError!ExprResult {
    if (args.len == 0) return error.MissingHttpGetArg;

    // Enable HTTP and runtime modules
    self.needs_http = true;
    self.needs_runtime = true;

    const arg = args[0];
    const arg_result = try expressions.visitExpr(self,arg);

    var buf = std.ArrayList(u8){};

    // Extract URL string from PyObject if needed
    // arg_result.code might be runtime.PyString.create() or a variable
    // For now, assume it's a string that needs getValue
    try buf.writer(self.temp_allocator).print(
        "http.getAsResponse(allocator, runtime.PyString.getValue({s}))",
        .{arg_result.code}
    );

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = true, // HTTP can fail
    };
}
