const std = @import("std");
const ast = @import("../ast.zig");
const CodegenError = @import("../codegen.zig").CodegenError;
const ExprResult = @import("../codegen.zig").ExprResult;
const ZigCodeGenerator = @import("../codegen.zig").ZigCodeGenerator;
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");

pub fn visitAttribute(self: *ZigCodeGenerator, attr: ast.Node.Attribute) CodegenError!ExprResult {
    const value_result = try expressions.visitExpr(self,attr.value.*);
    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("{s}.{s}", .{ value_result.code, attr.attr });
    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

pub fn visitClassInstantiation(self: *ZigCodeGenerator, class_name: []const u8, args: []ast.Node) CodegenError!ExprResult {
    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("{s}.init(", .{class_name});
    for (args, 0..) |arg, i| {
        if (i > 0) try buf.writer(self.temp_allocator).writeAll(", ");
        const arg_result = try expressions.visitExpr(self,arg);
        try buf.writer(self.temp_allocator).writeAll(arg_result.code);
    }
    try buf.writer(self.temp_allocator).writeAll(")");
    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}

/// Infer return type from method body by checking for return statements
fn inferReturnType(body: []ast.Node) []const u8 {
    for (body) |node| {
        if (node == .return_stmt) {
            // Method has a return statement, assume it returns i64 for now
            return "i64";
        }
    }
    // No return statement found, method returns void
    return "void";
}

pub fn visitClassDef(self: *ZigCodeGenerator, class: ast.Node.ClassDef) CodegenError!void {
    try self.class_names.put(class.name, {});

    // Count methods (excluding __init__) to determine if class needs 'var'
    var method_count: usize = 0;
    for (class.body) |node| {
        if (node == .function_def) {
            const func = node.function_def;
            if (!std.mem.eql(u8, func.name, "__init__")) {
                method_count += 1;
            }
        }
    }
    try self.class_has_methods.put(class.name, method_count > 0);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("const {s} = struct {{", .{class.name});
    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    self.indent();

    var init_method: ?ast.Node.FunctionDef = null;
    var methods = std.ArrayList(ast.Node.FunctionDef){};
    defer methods.deinit(self.allocator);

    for (class.body) |node| {
        switch (node) {
            .function_def => |func| {
                if (std.mem.eql(u8, func.name, "__init__")) {
                    init_method = func;
                } else {
                    try methods.append(self.allocator, func);
                }
            },
            else => {},
        }
    }

    if (init_method) |init_func| {
        for (init_func.body) |stmt| {
            switch (stmt) {
                .assign => |assign| {
                    for (assign.targets) |target| {
                        switch (target) {
                            .attribute => |attr| {
                                switch (attr.value.*) {
                                    .name => |name| {
                                        if (std.mem.eql(u8, name.id, "self")) {
                                            var field_buf = std.ArrayList(u8){};
                                            try field_buf.writer(self.temp_allocator).print("{s}: i64,", .{attr.attr});
                                            try self.emitOwned(try field_buf.toOwnedSlice(self.temp_allocator));
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        try self.emit("");
        buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).writeAll("pub fn init(");

        for (init_func.args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg.name, "self")) continue;
            if (i > 1) try buf.writer(self.temp_allocator).writeAll(", ");
            try buf.writer(self.temp_allocator).print("{s}: i64", .{arg.name});
        }

        try buf.writer(self.temp_allocator).print(") {s} {{", .{class.name});
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
        self.indent();

        buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print("return {s}{{", .{class.name});
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
        self.indent();

        for (init_func.body) |stmt| {
            switch (stmt) {
                .assign => |assign| {
                    for (assign.targets) |target| {
                        switch (target) {
                            .attribute => |attr| {
                                switch (attr.value.*) {
                                    .name => |name| {
                                        if (std.mem.eql(u8, name.id, "self")) {
                                            const value_result = try expressions.visitExpr(self,assign.value.*);
                                            buf = std.ArrayList(u8){};
                                            try buf.writer(self.temp_allocator).print(".{s} = {s},", .{ attr.attr, value_result.code });
                                            try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        self.dedent();
        try self.emit("};");
        self.dedent();
        try self.emit("}");
    }

    for (methods.items) |method| {
        try self.emit("");
        buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print("pub fn {s}(", .{method.name});

        for (method.args, 0..) |arg, i| {
            if (i > 0) try buf.writer(self.temp_allocator).writeAll(", ");
            if (std.mem.eql(u8, arg.name, "self")) {
                try buf.writer(self.temp_allocator).print("self: *{s}", .{class.name});
            } else {
                try buf.writer(self.temp_allocator).print("{s}: i64", .{arg.name});
            }
        }

        // Infer return type from method body
        const return_type = inferReturnType(method.body);
        try buf.writer(self.temp_allocator).print(") {s} {{", .{return_type});
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
        self.indent();

        for (method.body) |stmt| {
            try statements.visitNode(self, stmt);
        }

        self.dedent();
        try self.emit("}");
    }

    self.dedent();
    try self.emit("};");
}

/// Helper function to wrap primitive constants as PyObjects
fn wrapPrimitiveIfNeeded(self: *ZigCodeGenerator, node: ast.Node, arg_code: []const u8) ![]const u8 {
    switch (node) {
        .constant => |c| {
            switch (c.value) {
                .int => {
                    return try std.fmt.allocPrint(self.temp_allocator,
                        "try runtime.PyInt.create(allocator, {s})", .{arg_code});
                },
                .string => {
                    return try std.fmt.allocPrint(self.temp_allocator,
                        "try runtime.PyString.create(allocator, {s})", .{arg_code});
                },
                .bool => {
                    return try std.fmt.allocPrint(self.temp_allocator,
                        "runtime.PyBool.create({s})", .{arg_code});
                },
                .float => {
                    return try std.fmt.allocPrint(self.temp_allocator,
                        "try runtime.PyFloat.create(allocator, {s})", .{arg_code});
                },
            }
        },
        else => return arg_code,
    }
}

pub fn visitMethodCall(self: *ZigCodeGenerator, attr: ast.Node.Attribute, args: []ast.Node) CodegenError!ExprResult {
    const obj_result = try expressions.visitExpr(self,attr.value.*);
    const method_name = attr.attr;
    var buf = std.ArrayList(u8){};

    // Check if this is a user-defined class method call
    // If the object is a class instance (not a PyObject type), handle it first
    const is_class_method = blk: {
        switch (attr.value.*) {
            .name => |obj_name| {
                const var_type = self.var_types.get(obj_name.id);
                // If no type info or not a PyObject type, assume it's a class instance
                if (var_type == null) {
                    break :blk true;
                }
                // Not a PyObject built-in type
                if (!std.mem.eql(u8, var_type.?, "pyobject") and
                    !std.mem.eql(u8, var_type.?, "string") and
                    !std.mem.eql(u8, var_type.?, "list") and
                    !std.mem.eql(u8, var_type.?, "dict"))
                {
                    break :blk true;
                }
                break :blk false;
            },
            else => break :blk false,
        }
    };

    if (is_class_method) {
        // User-defined class method - generate obj.method(args)
        try buf.writer(self.temp_allocator).print("{s}.{s}(", .{ obj_result.code, method_name });
        for (args, 0..) |arg, i| {
            if (i > 0) try buf.writer(self.temp_allocator).writeAll(", ");
            const arg_result = try expressions.visitExpr(self,arg);
            if (arg_result.needs_try) {
                try buf.writer(self.temp_allocator).print("try {s}", .{arg_result.code});
            } else {
                try buf.writer(self.temp_allocator).writeAll(arg_result.code);
            }
        }
        try buf.writer(self.temp_allocator).writeAll(")");
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    }

    // String methods
    if (std.mem.eql(u8, method_name, "upper")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.upper(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "lower")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.lower(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "strip")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.strip(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "lstrip")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.lstrip(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "rstrip")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.rstrip(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "split")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.split(allocator, {s}, {s})", .{ obj_result.code, arg_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "replace")) {
        if (args.len != 2) return error.InvalidArguments;
        const arg1_result = try expressions.visitExpr(self,args[0]);
        const arg2_result = try expressions.visitExpr(self,args[1]);
        const arg1_code = try self.extractResultToStatement(arg1_result);
        const arg2_code = try self.extractResultToStatement(arg2_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.replace(allocator, {s}, {s}, {s})", .{ obj_result.code, arg1_code, arg2_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "capitalize")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.capitalize(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "swapcase")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.swapcase(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "title")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.title(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "center")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.center(allocator, {s}, {s})", .{ obj_result.code, arg_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "join")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.join(allocator, {s}, {s})", .{ obj_result.code, arg_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "startswith")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.startswith({s}, {s})", .{ obj_result.code, arg_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "endswith")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.endswith({s}, {s})", .{ obj_result.code, arg_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "isdigit")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.isdigit({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "isalpha")) {
        try buf.writer(self.temp_allocator).print("runtime.PyString.isalpha({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "find")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const arg_code = try self.extractResultToStatement(arg_result);
        try buf.writer(self.temp_allocator).print("runtime.PyString.find({s}, {s})", .{ obj_result.code, arg_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    }
    // List methods
    else if (std.mem.eql(u8, method_name, "append")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const wrapped_arg = try wrapPrimitiveIfNeeded(self, args[0], arg_result.code);
        try buf.writer(self.temp_allocator).print("runtime.PyList.append({s}, {s})", .{ obj_result.code, wrapped_arg });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "pop")) {
        try buf.writer(self.temp_allocator).print("runtime.PyList.pop(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "extend")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.temp_allocator).print("runtime.PyList.extend({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "reverse")) {
        try buf.writer(self.temp_allocator).print("runtime.PyList.reverse({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "remove")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const wrapped_arg = try wrapPrimitiveIfNeeded(self, args[0], arg_result.code);
        try buf.writer(self.temp_allocator).print("runtime.PyList.remove(allocator, {s}, {s})", .{ obj_result.code, wrapped_arg });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "count")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const wrapped_arg = try wrapPrimitiveIfNeeded(self, args[0], arg_result.code);
        try buf.writer(self.temp_allocator).print("runtime.PyList.count({s}, {s})", .{ obj_result.code, wrapped_arg });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "index")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        const wrapped_arg = try wrapPrimitiveIfNeeded(self, args[0], arg_result.code);
        try buf.writer(self.temp_allocator).print("runtime.PyList.index({s}, {s})", .{ obj_result.code, wrapped_arg });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "insert")) {
        if (args.len != 2) return error.InvalidArguments;
        const arg1_result = try expressions.visitExpr(self,args[0]);
        const arg2_result = try expressions.visitExpr(self,args[1]);
        const wrapped_arg2 = try wrapPrimitiveIfNeeded(self, args[1], arg2_result.code);
        try buf.writer(self.temp_allocator).print("runtime.PyList.insert(allocator, {s}, {s}, {s})", .{ obj_result.code, arg1_result.code, wrapped_arg2 });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "clear")) {
        try buf.writer(self.temp_allocator).print("runtime.PyList.clear(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "sort")) {
        try buf.writer(self.temp_allocator).print("runtime.PyList.sort({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "copy")) {
        try buf.writer(self.temp_allocator).print("runtime.PyList.copy(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    }
    // Dict methods
    else if (std.mem.eql(u8, method_name, "keys")) {
        try buf.writer(self.temp_allocator).print("runtime.PyDict.keys(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "values")) {
        try buf.writer(self.temp_allocator).print("runtime.PyDict.values(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "get")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArguments;
        const key_result = try expressions.visitExpr(self,args[0]);
        const key_code = if (key_result.needs_try)
            try std.fmt.allocPrint(self.allocator, "try {s}", .{key_result.code})
        else
            key_result.code;
        const default_result = if (args.len == 2)
            try expressions.visitExpr(self,args[1])
        else
            ExprResult{ .code = "runtime.PyNone", .needs_try = false };
        const default_code = if (default_result.needs_try)
            try std.fmt.allocPrint(self.allocator, "try {s}", .{default_result.code})
        else
            default_result.code;
        try buf.writer(self.temp_allocator).print("runtime.PyDict.get_method(allocator, {s}, {s}, {s})", .{ obj_result.code, key_code, default_code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "items")) {
        try buf.writer(self.temp_allocator).print("runtime.PyDict.items(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "update")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.temp_allocator).print("runtime.PyDict.update({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = true };
    } else {
        // Attempt to handle user-defined class methods
        // Generate generic method call: obj.method(args)
        // If obj is a class instance, Zig will resolve the method call
        buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print("{s}.{s}(", .{ obj_result.code, method_name });

        for (args, 0..) |arg, i| {
            if (i > 0) try buf.writer(self.temp_allocator).writeAll(", ");
            const arg_result = try expressions.visitExpr(self,arg);
            if (arg_result.needs_try) {
                try buf.writer(self.temp_allocator).print("try {s}", .{arg_result.code});
            } else {
                try buf.writer(self.temp_allocator).writeAll(arg_result.code);
            }
        }

        try buf.writer(self.temp_allocator).writeAll(")");
        return ExprResult{ .code = try buf.toOwnedSlice(self.temp_allocator), .needs_try = false };
    }
}
