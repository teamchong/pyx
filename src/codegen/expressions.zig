const std = @import("std");
const ast = @import("../ast.zig");
const CodegenError = @import("../codegen.zig").CodegenError;
const ExprResult = @import("../codegen.zig").ExprResult;
const ZigCodeGenerator = @import("../codegen.zig").ZigCodeGenerator;
const builtins = @import("builtins.zig");
const operators = @import("operators.zig");
const classes = @import("classes.zig");

/// Visit an expression node and generate code
pub fn visitExpr(self: *ZigCodeGenerator, node: ast.Node) CodegenError!ExprResult {
    return switch (node) {
        .name => |name| ExprResult{
            .code = name.id,
            .needs_try = false,
        },

        .constant => |constant| visitConstant(self, constant),

        .binop => |binop| operators.visitBinOp(self, binop),

        .unaryop => |unaryop| operators.visitUnaryOp(self, unaryop),

        .boolop => |boolop| operators.visitBoolOp(self, boolop),

        .attribute => |attr| classes.visitAttribute(self, attr),

        .call => |call| visitCall(self, call),

        .compare => |compare| operators.visitCompare(self, compare),

        .list => |list| visitList(self, list),

        .dict => |dict| visitDict(self, dict),

        .tuple => |tuple| visitTuple(self, tuple),

        .subscript => |sub| visitSubscript(self, sub),

        .await_expr => |await_expr| visitAwaitExpr(self, await_expr),

        else => error.UnsupportedExpression,
    };
}

/// Visit await expression
fn visitAwaitExpr(self: *ZigCodeGenerator, await_expr: ast.Node.AwaitExpr) CodegenError!ExprResult {
    // For Phase 1, we just evaluate the expression directly
    // Phase 2 will add proper suspend/resume logic
    const value_result = try visitExpr(self, await_expr.value.*);
    return value_result;
}

/// Visit a constant expression
fn visitConstant(self: *ZigCodeGenerator, constant: ast.Node.Constant) CodegenError!ExprResult {
    switch (constant.value) {
        .string => |str| {
            var buf = std.ArrayList(u8){};

            // Strip Python quotes and extract content
            var content: []const u8 = str;

            // Handle triple quotes
            if (str.len >= 6 and std.mem.startsWith(u8, str, "\"\"\"")) {
                content = str[3 .. str.len - 3];
            } else if (str.len >= 6 and std.mem.startsWith(u8, str, "'''")) {
                content = str[3 .. str.len - 3];
                // Handle single/double quotes
            } else if (str.len >= 2) {
                content = str[1 .. str.len - 1];
            }

            // Generate Zig code with proper escaping
            try buf.writer(self.temp_allocator).writeAll("runtime.PyString.create(allocator, \"");

            // Escape content for Zig string
            // Python escape sequences: already processed by Python lexer,
            // we just need to re-escape for Zig syntax
            var i: usize = 0;
            while (i < content.len) : (i += 1) {
                const c = content[i];
                switch (c) {
                    '\\' => {
                        // Check if this is an escape sequence
                        if (i + 1 < content.len) {
                            const next = content[i + 1];
                            switch (next) {
                                'n', 'r', 't', '\\', '\"', '\'', '0', 'a', 'b', 'f', 'v' => {
                                    // Pass through escape sequences
                                    try buf.writer(self.temp_allocator).writeByte('\\');
                                    i += 1;
                                    try buf.writer(self.temp_allocator).writeByte(content[i]);
                                },
                                'x', 'u', 'U' => {
                                    // Hex/Unicode escapes - pass through for now
                                    try buf.writer(self.temp_allocator).writeAll("\\\\");
                                },
                                else => {
                                    try buf.writer(self.temp_allocator).writeAll("\\\\");
                                },
                            }
                        } else {
                            try buf.writer(self.temp_allocator).writeAll("\\\\");
                        }
                    },
                    '\"' => try buf.writer(self.temp_allocator).writeAll("\\\""),
                    '\n' => try buf.writer(self.temp_allocator).writeAll("\\n"),
                    '\r' => try buf.writer(self.temp_allocator).writeAll("\\r"),
                    '\t' => try buf.writer(self.temp_allocator).writeAll("\\t"),
                    else => {
                        if (c >= 32 and c <= 126) {
                            try buf.writer(self.temp_allocator).writeByte(c);
                        } else {
                            // Non-printable - escape as hex
                            try buf.writer(self.temp_allocator).print("\\x{X:0>2}", .{c});
                        }
                    },
                }
            }

            try buf.writer(self.temp_allocator).writeAll("\")");

            return ExprResult{
                .code = try buf.toOwnedSlice(self.temp_allocator),
                .needs_try = true,
                .needs_decref = true, // String creates need cleanup
            };
        },
        .int => |num| {
            var buf = std.ArrayList(u8){};
            try buf.writer(self.temp_allocator).print("{d}", .{num});
            return ExprResult{
                .code = try buf.toOwnedSlice(self.temp_allocator),
                .needs_try = false,
            };
        },
        .bool => |b| {
            return ExprResult{
                .code = if (b) "true" else "false",
                .needs_try = false,
            };
        },
        .float => |f| {
            var buf = std.ArrayList(u8){};
            try buf.writer(self.temp_allocator).print("{d}", .{f});
            return ExprResult{
                .code = try buf.toOwnedSlice(self.temp_allocator),
                .needs_try = false,
            };
        },
    }
}

/// Visit a list literal expression
fn visitList(self: *ZigCodeGenerator, list: ast.Node.List) CodegenError!ExprResult {
    // Generate code to create a list literal
    // Strategy: Create empty list, then append each element
    self.needs_runtime = true;
    self.needs_allocator = true;

    // Unique variable name for the list
    const list_var = try std.fmt.allocPrint(self.allocator, "__list_{d}", .{self.temp_var_counter});
    self.temp_var_counter += 1;

    // Emit list creation as statements
    var create_buf = std.ArrayList(u8){};
    try create_buf.writer(self.temp_allocator).print("const {s} = try runtime.PyList.create(allocator);", .{list_var});
    try self.emitOwned(try create_buf.toOwnedSlice(self.temp_allocator));

    // Append each element
    for (list.elts) |elt| {
        const elt_result = try visitExpr(self, elt);
        var append_buf = std.ArrayList(u8){};

        // Check if element needs wrapping (constants need to be wrapped in PyObject)
        const needs_wrapping = switch (elt) {
            .constant => |c| switch (c.value) {
                .int, .float, .bool => true,
                else => false,
            },
            else => false,
        };

        if (needs_wrapping) {
            // Wrap constant in appropriate PyObject type
            const wrapped_code = switch (elt) {
                .constant => |c| switch (c.value) {
                    .int => try std.fmt.allocPrint(self.allocator, "try runtime.PyInt.create(allocator, {s})", .{elt_result.code}),
                    .float => try std.fmt.allocPrint(self.allocator, "try runtime.PyFloat.create(allocator, {s})", .{elt_result.code}),
                    .bool => try std.fmt.allocPrint(self.allocator, "try runtime.PyBool.create(allocator, {s})", .{elt_result.code}),
                    else => elt_result.code,
                },
                else => elt_result.code,
            };
            try append_buf.writer(self.temp_allocator).print("try runtime.PyList.append({s}, {s});", .{ list_var, wrapped_code });
        } else if (elt_result.needs_try) {
            try append_buf.writer(self.temp_allocator).print("try runtime.PyList.append({s}, try {s});", .{ list_var, elt_result.code });
        } else {
            try append_buf.writer(self.temp_allocator).print("try runtime.PyList.append({s}, {s});", .{ list_var, elt_result.code });
        }
        try self.emitOwned(try append_buf.toOwnedSlice(self.temp_allocator));
    }

    // Return the list variable name
    return ExprResult{
        .code = list_var,
        .needs_try = false,
    };
}

/// Visit a dict literal expression
fn visitDict(self: *ZigCodeGenerator, dict: ast.Node.Dict) CodegenError!ExprResult {
    // Generate code to create a dict literal
    // Strategy: Create empty dict, then set each key-value pair
    self.needs_runtime = true;
    self.needs_allocator = true;

    // Unique variable name for the dict
    const dict_var = try std.fmt.allocPrint(self.allocator, "__dict_{d}", .{self.temp_var_counter});
    self.temp_var_counter += 1;

    // Emit dict creation as statement
    var create_buf = std.ArrayList(u8){};
    try create_buf.writer(self.temp_allocator).print("const {s} = try runtime.PyDict.create(allocator);", .{dict_var});
    try self.emitOwned(try create_buf.toOwnedSlice(self.temp_allocator));

    // Set each key-value pair
    for (dict.keys, dict.values) |key, value| {
        const key_result = try visitExpr(self, key);
        const value_result = try visitExpr(self, value);
        var set_buf = std.ArrayList(u8){};

        // Extract string key from PyString or constant
        const key_code = switch (key) {
            .constant => |c| switch (c.value) {
                .string => |str| blk: {
                    // Strip quotes from string constant
                    var content: []const u8 = str;
                    if (str.len >= 2) {
                        content = str[1 .. str.len - 1];
                    }
                    break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{content});
                },
                else => key_result.code,
            },
            else => key_result.code,
        };

        // Wrap value if needed (constants need to be wrapped in PyObject)
        const needs_wrapping = switch (value) {
            .constant => |c| switch (c.value) {
                .int, .float, .bool => true,
                else => false,
            },
            else => false,
        };

        const value_code = if (needs_wrapping) blk: {
            const wrapped = switch (value) {
                .constant => |c| switch (c.value) {
                    .int => try std.fmt.allocPrint(self.allocator, "try runtime.PyInt.create(allocator, {s})", .{value_result.code}),
                    .float => try std.fmt.allocPrint(self.allocator, "try runtime.PyFloat.create(allocator, {s})", .{value_result.code}),
                    .bool => try std.fmt.allocPrint(self.allocator, "try runtime.PyBool.create(allocator, {s})", .{value_result.code}),
                    else => value_result.code,
                },
                else => value_result.code,
            };
            break :blk wrapped;
        } else if (value_result.needs_try) blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "try {s}", .{value_result.code});
        } else value_result.code;

        try set_buf.writer(self.temp_allocator).print("try runtime.PyDict.set({s}, {s}, {s});", .{ dict_var, key_code, value_code });
        try self.emitOwned(try set_buf.toOwnedSlice(self.temp_allocator));
    }

    // Return the dict variable name
    return ExprResult{
        .code = dict_var,
        .needs_try = false,
    };
}

/// Visit a tuple literal expression
fn visitTuple(self: *ZigCodeGenerator, tuple: ast.Node.Tuple) CodegenError!ExprResult {
    // Generate code to create a tuple literal
    // Strategy: Create tuple, then set each element
    self.needs_runtime = true;
    self.needs_allocator = true;

    // Unique variable name for the tuple
    const tuple_var = try std.fmt.allocPrint(self.allocator, "__tuple_{d}", .{self.temp_var_counter});
    self.temp_var_counter += 1;

    // Emit tuple creation as statement
    var create_buf = std.ArrayList(u8){};
    try create_buf.writer(self.temp_allocator).print("const {s} = try runtime.PyTuple.create(allocator, {d});", .{ tuple_var, tuple.elts.len });
    try self.emitOwned(try create_buf.toOwnedSlice(self.temp_allocator));

    // Set each element
    for (tuple.elts, 0..) |elt, i| {
        const elt_result = try visitExpr(self, elt);
        var set_buf = std.ArrayList(u8){};

        // Check if element needs wrapping (constants need to be wrapped in PyObject)
        const needs_wrapping = switch (elt) {
            .constant => |c| switch (c.value) {
                .int, .float, .bool => true,
                else => false,
            },
            else => false,
        };

        if (needs_wrapping) {
            // Wrap constant in appropriate PyObject type
            const wrapped_code = switch (elt) {
                .constant => |c| switch (c.value) {
                    .int => try std.fmt.allocPrint(self.allocator, "try runtime.PyInt.create(allocator, {s})", .{elt_result.code}),
                    .float => try std.fmt.allocPrint(self.allocator, "try runtime.PyFloat.create(allocator, {s})", .{elt_result.code}),
                    .bool => try std.fmt.allocPrint(self.allocator, "try runtime.PyBool.create(allocator, {s})", .{elt_result.code}),
                    else => elt_result.code,
                },
                else => elt_result.code,
            };
            try set_buf.writer(self.temp_allocator).print("runtime.PyTuple.setItem({s}, {d}, {s});", .{ tuple_var, i, wrapped_code });
        } else if (elt_result.needs_try) {
            try set_buf.writer(self.temp_allocator).print("runtime.PyTuple.setItem({s}, {d}, try {s});", .{ tuple_var, i, elt_result.code });
        } else {
            try set_buf.writer(self.temp_allocator).print("runtime.PyTuple.setItem({s}, {d}, {s});", .{ tuple_var, i, elt_result.code });
        }
        try self.emitOwned(try set_buf.toOwnedSlice(self.temp_allocator));
    }

    // Return the tuple variable name
    return ExprResult{
        .code = tuple_var,
        .needs_try = false,
    };
}

/// Visit a subscript expression (indexing or slicing)
fn visitSubscript(self: *ZigCodeGenerator, sub: ast.Node.Subscript) CodegenError!ExprResult {
    self.needs_runtime = true;
    self.needs_allocator = true;

    const value_result = try visitExpr(self, sub.value.*);
    var buf = std.ArrayList(u8){};

    switch (sub.slice) {
        .index => |idx| {
            // Simple indexing: items[0] or dict["key"]
            const idx_result = try visitExpr(self, idx.*);

            // Determine if value is a string, dict, or list by checking variable type
            const value_type = blk: {
                switch (sub.value.*) {
                    .name => |name| {
                        if (self.var_types.get(name.id)) |var_type| {
                            break :blk var_type;
                        }
                    },
                    .constant => |c| {
                        if (c.value == .string) break :blk "string";
                    },
                    else => {},
                }
                break :blk "list"; // default to list
            };

            if (std.mem.eql(u8, value_type, "string")) {
                // String indexing
                if (idx_result.needs_try) {
                    try buf.writer(self.temp_allocator).print("runtime.PyString.charAt(allocator, {s}, try {s})", .{ value_result.code, idx_result.code });
                } else {
                    try buf.writer(self.temp_allocator).print("runtime.PyString.charAt(allocator, {s}, {s})", .{ value_result.code, idx_result.code });
                }
            } else if (std.mem.eql(u8, value_type, "tuple")) {
                // Tuple indexing
                if (idx_result.needs_try) {
                    try buf.writer(self.temp_allocator).print("runtime.PyTuple.getItem({s}, @intCast(try {s}))", .{ value_result.code, idx_result.code });
                } else {
                    try buf.writer(self.temp_allocator).print("runtime.PyTuple.getItem({s}, @intCast({s}))", .{ value_result.code, idx_result.code });
                }
            } else if (std.mem.eql(u8, value_type, "dict")) {
                // Dict indexing - extract string key
                const key_code = switch (idx.*) {
                    .constant => |c| switch (c.value) {
                        .string => |str| blk: {
                            // Strip quotes from string constant
                            var content: []const u8 = str;
                            if (str.len >= 2) {
                                content = str[1 .. str.len - 1];
                            }
                            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{content});
                        },
                        else => idx_result.code,
                    },
                    else => idx_result.code,
                };
                try buf.writer(self.temp_allocator).print("runtime.PyDict.get({s}, {s}).?", .{ value_result.code, key_code });
                // Dict.get() returns optional, not error union, so no try needed
                return ExprResult{
                    .code = try buf.toOwnedSlice(self.temp_allocator),
                    .needs_try = false,
                };
            } else {
                // List indexing
                if (idx_result.needs_try) {
                    try buf.writer(self.temp_allocator).print("runtime.PyList.get({s}, try {s})", .{ value_result.code, idx_result.code });
                } else {
                    try buf.writer(self.temp_allocator).print("runtime.PyList.get({s}, {s})", .{ value_result.code, idx_result.code });
                }
            }

            return ExprResult{
                .code = try buf.toOwnedSlice(self.temp_allocator),
                .needs_try = true,
            };
        },
        .slice => |range| {
            // Slicing: items[1:3]
            const is_string = blk: {
                switch (sub.value.*) {
                    .name => |name| {
                        if (self.var_types.get(name.id)) |var_type| {
                            break :blk std.mem.eql(u8, var_type, "string");
                        }
                    },
                    .constant => |c| {
                        break :blk c.value == .string;
                    },
                    else => {},
                }
                break :blk false;
            };

            // Generate lower bound code
            const lower_code = if (range.lower) |lower| blk: {
                const result = try visitExpr(self, lower.*);
                break :blk result.code;
            } else "null";

            // Generate upper bound code
            const upper_code = if (range.upper) |upper| blk: {
                const result = try visitExpr(self, upper.*);
                break :blk result.code;
            } else "null";

            // Generate step code (if provided)
            const step_code = if (range.step) |step| blk: {
                const result = try visitExpr(self, step.*);
                break :blk result.code;
            } else "null";

            if (is_string) {
                // String slicing
                if (range.step == null) {
                    try buf.writer(self.temp_allocator).print("runtime.PyString.slice(allocator, {s}, {s}, {s})", .{ value_result.code, lower_code, upper_code });
                } else {
                    try buf.writer(self.temp_allocator).print("runtime.PyString.sliceWithStep(allocator, {s}, {s}, {s}, {s})", .{ value_result.code, lower_code, upper_code, step_code });
                }
            } else {
                // List slicing
                if (range.step == null) {
                    try buf.writer(self.temp_allocator).print("runtime.PyList.slice(allocator, {s}, {s}, {s})", .{ value_result.code, lower_code, upper_code });
                } else {
                    try buf.writer(self.temp_allocator).print("runtime.PyList.sliceWithStep(allocator, {s}, {s}, {s}, {s})", .{ value_result.code, lower_code, upper_code, step_code });
                }
            }

            return ExprResult{
                .code = try buf.toOwnedSlice(self.temp_allocator),
                .needs_try = true,
                .needs_decref = true,
            };
        },
    }
}

/// Visit a function call expression
pub fn visitCall(self: *ZigCodeGenerator, call: ast.Node.Call) CodegenError!ExprResult {
    switch (call.func.*) {
        .name => |func_name| {
            // Handle built-in functions
            if (std.mem.eql(u8, func_name.id, "print")) {
                return builtins.visitPrintCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "len")) {
                return builtins.visitLenCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "abs")) {
                return builtins.visitAbsCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "round")) {
                return builtins.visitRoundCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "min")) {
                return builtins.visitMinCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "max")) {
                return builtins.visitMaxCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "sum")) {
                return builtins.visitSumCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "all")) {
                return builtins.visitAllCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "any")) {
                return builtins.visitAnyCall(self, call.args);
            } else if (std.mem.eql(u8, func_name.id, "http_get")) {
                return builtins.visitHttpGetCall(self, call.args);
            } else {
                // Check if this is a class instantiation
                if (self.class_names.contains(func_name.id)) {
                    return classes.visitClassInstantiation(self, func_name.id, call.args);
                }

                // Check if this is a user-defined function
                if (self.function_names.contains(func_name.id)) {
                    return visitUserFunctionCall(self, func_name.id, call.args);
                }
                return error.UnsupportedFunction;
            }
        },
        .attribute => |attr| {
            // Handle method calls like obj.method(args)
            return classes.visitMethodCall(self, attr, call.args);
        },
        else => return error.UnsupportedCall,
    }
}

/// Visit a user-defined function call
fn visitUserFunctionCall(self: *ZigCodeGenerator, func_name: []const u8, args: []ast.Node) CodegenError!ExprResult {
    var buf = std.ArrayList(u8){};

    // Generate function call: func_name(arg1, arg2, ...)
    try buf.writer(self.temp_allocator).print("{s}(", .{func_name});

    // Add arguments
    for (args, 0..) |arg, i| {
        if (i > 0) {
            try buf.writer(self.temp_allocator).writeAll(", ");
        }
        const arg_result = try visitExpr(self, arg);
        try buf.writer(self.temp_allocator).writeAll(arg_result.code);
    }

    // Add allocator if needed
    if (self.needs_allocator and args.len > 0) {
        try buf.writer(self.temp_allocator).writeAll(", allocator");
    } else if (self.needs_allocator) {
        try buf.writer(self.temp_allocator).writeAll("allocator");
    }

    try buf.writer(self.temp_allocator).writeAll(")");

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}
