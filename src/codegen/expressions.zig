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

        else => error.UnsupportedExpression,
    };
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
            try buf.writer(self.allocator).writeAll("runtime.PyString.create(allocator, \"");

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
                                    try buf.writer(self.allocator).writeByte('\\');
                                    i += 1;
                                    try buf.writer(self.allocator).writeByte(content[i]);
                                },
                                'x', 'u', 'U' => {
                                    // Hex/Unicode escapes - pass through for now
                                    try buf.writer(self.allocator).writeAll("\\\\");
                                },
                                else => {
                                    try buf.writer(self.allocator).writeAll("\\\\");
                                },
                            }
                        } else {
                            try buf.writer(self.allocator).writeAll("\\\\");
                        }
                    },
                    '\"' => try buf.writer(self.allocator).writeAll("\\\""),
                    '\n' => try buf.writer(self.allocator).writeAll("\\n"),
                    '\r' => try buf.writer(self.allocator).writeAll("\\r"),
                    '\t' => try buf.writer(self.allocator).writeAll("\\t"),
                    else => {
                        if (c >= 32 and c <= 126) {
                            try buf.writer(self.allocator).writeByte(c);
                        } else {
                            // Non-printable - escape as hex
                            try buf.writer(self.allocator).print("\\x{X:0>2}", .{c});
                        }
                    },
                }
            }

            try buf.writer(self.allocator).writeAll("\")");

            return ExprResult{
                .code = try buf.toOwnedSlice(self.allocator),
                .needs_try = true,
            };
        },
        .int => |num| {
            var buf = std.ArrayList(u8){};
            try buf.writer(self.allocator).print("{d}", .{num});
            return ExprResult{
                .code = try buf.toOwnedSlice(self.allocator),
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
            try buf.writer(self.allocator).print("{d}", .{f});
            return ExprResult{
                .code = try buf.toOwnedSlice(self.allocator),
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
    try create_buf.writer(self.allocator).print("const {s} = try runtime.PyList.create(allocator);", .{list_var});
    try self.emit(try create_buf.toOwnedSlice(self.allocator));

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
            try append_buf.writer(self.allocator).print("try runtime.PyList.append({s}, {s});", .{ list_var, wrapped_code });
        } else if (elt_result.needs_try) {
            try append_buf.writer(self.allocator).print("try runtime.PyList.append({s}, try {s});", .{ list_var, elt_result.code });
        } else {
            try append_buf.writer(self.allocator).print("try runtime.PyList.append({s}, {s});", .{ list_var, elt_result.code });
        }
        try self.emit(try append_buf.toOwnedSlice(self.allocator));
    }

    // Return the list variable name
    return ExprResult{
        .code = list_var,
        .needs_try = false,
    };
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
    try buf.writer(self.allocator).print("{s}(", .{func_name});

    // Add arguments
    for (args, 0..) |arg, i| {
        if (i > 0) {
            try buf.writer(self.allocator).writeAll(", ");
        }
        const arg_result = try visitExpr(self, arg);
        try buf.writer(self.allocator).writeAll(arg_result.code);
    }

    // Add allocator if needed
    if (self.needs_allocator and args.len > 0) {
        try buf.writer(self.allocator).writeAll(", allocator");
    } else if (self.needs_allocator) {
        try buf.writer(self.allocator).writeAll("allocator");
    }

    try buf.writer(self.allocator).writeAll(")");

    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
        .needs_try = false,
    };
}
