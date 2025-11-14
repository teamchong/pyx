const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const statements = @import("statements.zig");
const expressions = @import("expressions.zig");

const ZigCodeGenerator = codegen.ZigCodeGenerator;
const ExprResult = codegen.ExprResult;
const CodegenError = codegen.CodegenError;

/// Infer parameter type by analyzing function body usage
fn inferParamType(self: *ZigCodeGenerator, param_name: []const u8, body: []const ast.Node) []const u8 {
    for (body) |node| {
        const param_type = inferParamTypeInNode(self, param_name, node);
        if (param_type) |t| return t;
    }
    return "i64"; // Default to i64
}

/// Recursively check node for parameter usage patterns
fn inferParamTypeInNode(self: *ZigCodeGenerator, param_name: []const u8, node: ast.Node) ?[]const u8 {
    switch (node) {
        .binop => |binop| {
            // Check if param is used in string concatenation
            if (binop.op == .Add) {
                // Check if ANY part of this Add expression involves strings and the parameter
                const has_string = containsString(self, node);
                const refs_param = nodeReferencesName(node, param_name);
                if (has_string and refs_param) {
                    return "*runtime.PyObject";
                }
            }
            // Recurse
            if (inferParamTypeInNode(self, param_name, binop.left.*)) |t| return t;
            if (inferParamTypeInNode(self, param_name, binop.right.*)) |t| return t;
        },
        .attribute => |attr| {
            // If param has method calls (param.upper()), it's a PyObject
            if (nodeReferencesName(attr.value.*, param_name)) {
                return "*runtime.PyObject";
            }
        },
        .subscript => |subscript| {
            // If param is subscripted (param[i]), it's a PyObject (list/dict/tuple)
            if (nodeReferencesName(subscript.value.*, param_name)) {
                return "*runtime.PyObject";
            }
            // Recurse into slice index if it's an index subscript
            switch (subscript.slice) {
                .index => |idx| {
                    if (inferParamTypeInNode(self, param_name, idx.*)) |t| return t;
                },
                .slice => {},
            }
        },
        .call => |call| {
            // Check if param is passed to len() - indicates it's a collection
            switch (call.func.*) {
                .name => |func_name| {
                    if (std.mem.eql(u8, func_name.id, "len")) {
                        for (call.args) |arg| {
                            if (nodeReferencesName(arg, param_name)) {
                                return "*runtime.PyObject";
                            }
                        }
                    }
                },
                else => {},
            }
            // Check if param is passed to a function expecting PyObject
            for (call.args) |arg| {
                if (inferParamTypeInNode(self, param_name, arg)) |t| return t;
            }
        },
        .assign => |assign| {
            // Check if assignment value references param
            if (inferParamTypeInNode(self, param_name, assign.value.*)) |t| return t;
        },
        .if_stmt => |if_stmt| {
            for (if_stmt.body) |stmt| {
                if (inferParamTypeInNode(self, param_name, stmt)) |t| return t;
            }
            for (if_stmt.else_body) |stmt| {
                if (inferParamTypeInNode(self, param_name, stmt)) |t| return t;
            }
        },
        .while_stmt => |while_stmt| {
            // Check condition
            if (inferParamTypeInNode(self, param_name, while_stmt.condition.*)) |t| return t;
            // Check body
            for (while_stmt.body) |stmt| {
                if (inferParamTypeInNode(self, param_name, stmt)) |t| return t;
            }
        },
        .return_stmt => |ret| {
            if (ret.value) |val| {
                return inferParamTypeInNode(self, param_name, val.*);
            }
        },
        else => {},
    }
    return null;
}

/// Check if a node represents a string value
fn isStringNode(self: *ZigCodeGenerator, node: ast.Node) bool {
    switch (node) {
        .constant => |c| return c.value == .string,
        .name => |name| {
            if (self.var_types.get(name.id)) |var_type| {
                return std.mem.eql(u8, var_type, "string");
            }
        },
        else => {},
    }
    return false;
}

/// Check if expression tree contains any string values
fn containsString(self: *ZigCodeGenerator, node: ast.Node) bool {
    switch (node) {
        .constant => |c| return c.value == .string,
        .name => |name| {
            if (self.var_types.get(name.id)) |var_type| {
                return std.mem.eql(u8, var_type, "string");
            }
            return false;
        },
        .binop => |binop| {
            return containsString(self, binop.left.*) or containsString(self, binop.right.*);
        },
        else => return false,
    }
}

/// Check if node references a specific variable name
fn nodeReferencesName(node: ast.Node, target_name: []const u8) bool {
    switch (node) {
        .name => |name| return std.mem.eql(u8, name.id, target_name),
        .binop => |binop| {
            return nodeReferencesName(binop.left.*, target_name) or
                nodeReferencesName(binop.right.*, target_name);
        },
        .attribute => |attr| return nodeReferencesName(attr.value.*, target_name),
        .call => |call| {
            if (nodeReferencesName(call.func.*, target_name)) return true;
            for (call.args) |arg| {
                if (nodeReferencesName(arg, target_name)) return true;
            }
            return false;
        },
        else => {},
    }
    return false;
}

/// Infer return type by analyzing return statements
fn inferReturnType(self: *ZigCodeGenerator, body: []const ast.Node) ![]const u8 {
    for (body) |node| {
        if (node == .return_stmt) {
            if (node.return_stmt.value) |val| {
                // Analyze the return value to determine type
                switch (val.*) {
                    .constant => |c| {
                        switch (c.value) {
                            .int => return "i64",
                            .string => return "*runtime.PyObject",
                            else => return "i64",
                        }
                    },
                    .list => return "*runtime.PyObject",
                    .dict => return "*runtime.PyObject",
                    .tuple => return "*runtime.PyObject",
                    .name => |name| {
                        // Check variable type
                        if (self.var_types.get(name.id)) |var_type| {
                            if (std.mem.eql(u8, var_type, "string") or
                                std.mem.eql(u8, var_type, "list") or
                                std.mem.eql(u8, var_type, "dict") or
                                std.mem.eql(u8, var_type, "tuple") or
                                std.mem.eql(u8, var_type, "pyobject"))
                            {
                                return "*runtime.PyObject";
                            } else if (std.mem.eql(u8, var_type, "int")) {
                                return "i64";
                            }
                        }
                        return "i64";
                    },
                    .binop => |binop| {
                        // String concatenation returns PyObject
                        if (binop.op == .Add) {
                            if (isStringNode(self, binop.left.*) or isStringNode(self, binop.right.*)) {
                                return "*runtime.PyObject";
                            }
                        }
                        return "i64";
                    },
                    .call => {
                        // Recursive call - analyze other returns or default to i64
                        return "i64";
                    },
                    else => return "i64",
                }
            }
            return "void";
        }
        // Recursively check nested statements
        const nested_type = inferReturnTypeInNode(self, node);
        if (nested_type) |t| return t;
    }
    return "void";
}

/// Check for return statements in nested nodes
fn inferReturnTypeInNode(self: *ZigCodeGenerator, node: ast.Node) ?[]const u8 {
    switch (node) {
        .if_stmt => |if_stmt| {
            // Check body for return statements
            for (if_stmt.body) |stmt| {
                if (stmt == .return_stmt) {
                    if (stmt.return_stmt.value) |val| {
                        // Inline the type inference
                        switch (val.*) {
                            .constant => |c| {
                                switch (c.value) {
                                    .int => return "i64",
                                    .string => return "*runtime.PyObject",
                                    else => return "i64",
                                }
                            },
                            .list => return "*runtime.PyObject",
                            .dict => return "*runtime.PyObject",
                            .tuple => return "*runtime.PyObject",
                            .name => |name| {
                                if (self.var_types.get(name.id)) |var_type| {
                                    if (std.mem.eql(u8, var_type, "string") or
                                        std.mem.eql(u8, var_type, "list") or
                                        std.mem.eql(u8, var_type, "dict") or
                                        std.mem.eql(u8, var_type, "tuple") or
                                        std.mem.eql(u8, var_type, "pyobject"))
                                    {
                                        return "*runtime.PyObject";
                                    } else if (std.mem.eql(u8, var_type, "int")) {
                                        return "i64";
                                    }
                                }
                                return "i64";
                            },
                            .binop => |binop| {
                                if (binop.op == .Add) {
                                    if (isStringNode(self, binop.left.*) or isStringNode(self, binop.right.*)) {
                                        return "*runtime.PyObject";
                                    }
                                }
                                return "i64";
                            },
                            else => return "i64",
                        }
                    }
                }
            }
            // Check else body
            for (if_stmt.else_body) |stmt| {
                if (stmt == .return_stmt) {
                    if (stmt.return_stmt.value) |val| {
                        switch (val.*) {
                            .constant => |c| {
                                switch (c.value) {
                                    .int => return "i64",
                                    .string => return "*runtime.PyObject",
                                    else => return "i64",
                                }
                            },
                            .list => return "*runtime.PyObject",
                            .dict => return "*runtime.PyObject",
                            .tuple => return "*runtime.PyObject",
                            .name => |name| {
                                if (self.var_types.get(name.id)) |var_type| {
                                    if (std.mem.eql(u8, var_type, "string") or
                                        std.mem.eql(u8, var_type, "list") or
                                        std.mem.eql(u8, var_type, "dict") or
                                        std.mem.eql(u8, var_type, "tuple") or
                                        std.mem.eql(u8, var_type, "pyobject"))
                                    {
                                        return "*runtime.PyObject";
                                    } else if (std.mem.eql(u8, var_type, "int")) {
                                        return "i64";
                                    }
                                }
                                return "i64";
                            },
                            .binop => |binop| {
                                if (binop.op == .Add) {
                                    if (isStringNode(self, binop.left.*) or isStringNode(self, binop.right.*)) {
                                        return "*runtime.PyObject";
                                    }
                                }
                                return "i64";
                            },
                            else => return "i64",
                        }
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Check if function body needs allocator (uses runtime functions)
fn needsAllocator(body: []const ast.Node) bool {
    for (body) |node| {
        if (nodeNeedsAllocator(node)) return true;
    }
    return false;
}

fn nodeNeedsAllocator(node: ast.Node) bool {
    switch (node) {
        .constant => |c| return c.value == .string,
        .list => return true,
        .dict => return true,
        .tuple => return true,
        .subscript => return true, // Subscripting PyObjects returns new references that need decref
        .binop => |binop| {
            return nodeNeedsAllocator(binop.left.*) or nodeNeedsAllocator(binop.right.*);
        },
        .call => |call| {
            // Check if this is len() which needs runtime
            switch (call.func.*) {
                .name => |func_name| {
                    if (std.mem.eql(u8, func_name.id, "len")) {
                        return true;
                    }
                },
                else => {},
            }
            for (call.args) |arg| {
                if (nodeNeedsAllocator(arg)) return true;
            }
            return false;
        },
        .if_stmt => |if_stmt| {
            for (if_stmt.body) |stmt| {
                if (nodeNeedsAllocator(stmt)) return true;
            }
            for (if_stmt.else_body) |stmt| {
                if (nodeNeedsAllocator(stmt)) return true;
            }
            return false;
        },
        .while_stmt => |while_stmt| {
            // Check condition
            if (nodeNeedsAllocator(while_stmt.condition.*)) return true;
            // Check body
            for (while_stmt.body) |stmt| {
                if (nodeNeedsAllocator(stmt)) return true;
            }
            return false;
        },
        .return_stmt => |ret| {
            if (ret.value) |val| return nodeNeedsAllocator(val.*);
            return false;
        },
        .assign => |assign| {
            return nodeNeedsAllocator(assign.value.*);
        },
        else => return false,
    }
}

/// Generate code for function definition
pub fn visitFunctionDef(self: *ZigCodeGenerator, func: ast.Node.FunctionDef) CodegenError!void {
    if (func.is_async) {
        try emitAsyncFunction(self, func);
    } else {
        try emitSyncFunction(self, func);
    }
}

/// Generate synchronous function
fn emitSyncFunction(self: *ZigCodeGenerator, func: ast.Node.FunctionDef) CodegenError!void {
    // Infer return type from function body
    const return_type = try inferReturnType(self, func.body);

    // Check if function needs error propagation (uses runtime functions or has try expressions)
    const func_needs_allocator = needsAllocator(func.body);
    const needs_try = std.mem.eql(u8, return_type, "*runtime.PyObject") or func_needs_allocator;

    // Store function metadata for calls
    try self.function_needs_allocator.put(func.name, func_needs_allocator);

    // Store the actual return type including error union if needed
    const actual_return_type = if (needs_try and !std.mem.eql(u8, return_type, "*runtime.PyObject"))
        try std.fmt.allocPrint(self.temp_allocator, "!{s}", .{return_type})
    else
        return_type;
    try self.function_return_types.put(func.name, actual_return_type);

    var buf = std.ArrayList(u8){};

    // Start function signature
    if (needs_try) {
        try buf.writer(self.temp_allocator).print("fn {s}(", .{func.name});
    } else {
        try buf.writer(self.temp_allocator).print("fn {s}(", .{func.name});
    }

    // Add parameters with inferred types
    for (func.args, 0..) |arg, i| {
        if (i > 0) {
            try buf.writer(self.temp_allocator).writeAll(", ");
        }
        const param_type = inferParamType(self, arg.name, func.body);
        try buf.writer(self.temp_allocator).print("{s}: {s}", .{ arg.name, param_type });
    }

    // Add allocator parameter if needed
    if (func_needs_allocator) {
        if (func.args.len > 0) {
            try buf.writer(self.temp_allocator).writeAll(", ");
        }
        try buf.writer(self.temp_allocator).writeAll("allocator: std.mem.Allocator");
    }

    // Close signature with return type
    if (needs_try) {
        try buf.writer(self.temp_allocator).print(") !{s} {{", .{return_type});
    } else {
        try buf.writer(self.temp_allocator).print(") {s} {{", .{return_type});
    }

    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    self.indent();

    // Generate function body
    for (func.body) |stmt| {
        try statements.visitNode(self, stmt);
    }

    self.dedent();
    try self.emit("}");
}

/// Generate async function as frame struct
fn emitAsyncFunction(self: *ZigCodeGenerator, func: ast.Node.FunctionDef) CodegenError!void {
    // Generate frame struct
    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("const {s}Frame = struct {{", .{func.name});
    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    self.indent();

    // State enum
    try self.emit("state: enum { start, running, done } = .start,");

    // Parameters as fields
    for (func.args) |arg| {
        var param_buf = std.ArrayList(u8){};
        try param_buf.writer(self.temp_allocator).print("{s}: i64,", .{arg.name});
        try self.emitOwned(try param_buf.toOwnedSlice(self.temp_allocator));
    }

    // Result field
    try self.emit("result: ?i64 = null,");
    try self.emit("");

    // Init function
    try self.emit("pub fn init(");
    self.indent();
    for (func.args, 0..) |arg, i| {
        var init_buf = std.ArrayList(u8){};
        if (i == func.args.len - 1) {
            try init_buf.writer(self.temp_allocator).print("{s}: i64", .{arg.name});
        } else {
            try init_buf.writer(self.temp_allocator).print("{s}: i64,", .{arg.name});
        }
        try self.emitOwned(try init_buf.toOwnedSlice(self.temp_allocator));
    }
    self.dedent();
    try self.emit(") @This() {");
    self.indent();
    try self.emit("return .{");
    self.indent();
    for (func.args) |arg| {
        var field_buf = std.ArrayList(u8){};
        try field_buf.writer(self.temp_allocator).print(".{s} = {s},", .{ arg.name, arg.name });
        try self.emitOwned(try field_buf.toOwnedSlice(self.temp_allocator));
    }
    self.dedent();
    try self.emit("};");
    self.dedent();
    try self.emit("}");
    try self.emit("");

    // Resume function (simplified for Phase 1)
    try self.emit("pub fn resume(self: *@This()) !?i64 {");
    self.indent();
    try self.emit("switch (self.state) {");
    self.indent();
    try self.emit(".start => {");
    self.indent();
    try self.emit("self.state = .running;");

    // Generate function body
    for (func.body) |stmt| {
        try statements.visitNode(self, stmt);
    }

    try self.emit("self.state = .done;");
    try self.emit("return self.result;");
    self.dedent();
    try self.emit("},");
    try self.emit(".running, .done => return self.result,");
    self.dedent();
    try self.emit("}");
    self.dedent();
    try self.emit("}");

    self.dedent();
    try self.emit("};");
    try self.emit("");

    // Wrapper function that creates frame and runs it
    var wrapper_buf = std.ArrayList(u8){};
    try wrapper_buf.writer(self.temp_allocator).print("fn {s}(", .{func.name});
    for (func.args, 0..) |arg, i| {
        if (i > 0) try wrapper_buf.writer(self.temp_allocator).writeAll(", ");
        try wrapper_buf.writer(self.temp_allocator).print("{s}: i64", .{arg.name});
    }
    try wrapper_buf.writer(self.temp_allocator).writeAll(") !i64 {");
    try self.emitOwned(try wrapper_buf.toOwnedSlice(self.temp_allocator));

    self.indent();
    var init_buf = std.ArrayList(u8){};
    try init_buf.writer(self.temp_allocator).print("var frame = {s}Frame.init(", .{func.name});
    for (func.args, 0..) |arg, i| {
        if (i > 0) try init_buf.writer(self.temp_allocator).writeAll(", ");
        try init_buf.writer(self.temp_allocator).print("{s}", .{arg.name});
    }
    try init_buf.writer(self.temp_allocator).writeAll(");");
    try self.emitOwned(try init_buf.toOwnedSlice(self.temp_allocator));

    try self.emit("return (try frame.resume()).?;");
    self.dedent();
    try self.emit("}");
}

/// Generate code for user-defined function call
pub fn visitUserFunctionCall(self: *ZigCodeGenerator, func_name: []const u8, args: []ast.Node) CodegenError!ExprResult {
    var buf = std.ArrayList(u8){};

    // Check if function needs allocator and return type
    const func_needs_allocator = self.function_needs_allocator.get(func_name) orelse false;
    const return_type = self.function_return_types.get(func_name) orelse "i64";
    const needs_try = std.mem.eql(u8, return_type, "*runtime.PyObject") or
        (return_type.len > 0 and return_type[0] == '!'); // Error union types start with '!'

    // Generate function call: func_name(arg1, arg2, ...)
    try buf.writer(self.temp_allocator).print("{s}(", .{func_name});

    // Add arguments
    for (args, 0..) |arg, i| {
        if (i > 0) {
            try buf.writer(self.temp_allocator).writeAll(", ");
        }
        const arg_result = try expressions.visitExpr(self, arg);
        if (arg_result.needs_try) {
            try buf.writer(self.temp_allocator).print("try {s}", .{arg_result.code});
        } else {
            try buf.writer(self.temp_allocator).writeAll(arg_result.code);
        }
    }

    // Add allocator only if this specific function needs it
    if (func_needs_allocator) {
        if (args.len > 0) {
            try buf.writer(self.temp_allocator).writeAll(", allocator");
        } else {
            try buf.writer(self.temp_allocator).writeAll("allocator");
        }
    }

    try buf.writer(self.temp_allocator).writeAll(")");

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = needs_try,
    };
}
