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
    try buf.writer(self.allocator).print("{s}.{s}", .{ value_result.code, attr.attr });
    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
        .needs_try = false,
    };
}

pub fn visitClassInstantiation(self: *ZigCodeGenerator, class_name: []const u8, args: []ast.Node) CodegenError!ExprResult {
    var buf = std.ArrayList(u8){};
    try buf.writer(self.allocator).print("{s}.init(", .{class_name});
    for (args, 0..) |arg, i| {
        if (i > 0) try buf.writer(self.allocator).writeAll(", ");
        const arg_result = try expressions.visitExpr(self,arg);
        try buf.writer(self.allocator).writeAll(arg_result.code);
    }
    try buf.writer(self.allocator).writeAll(")");
    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
        .needs_try = false,
    };
}

pub fn visitClassDef(self: *ZigCodeGenerator, class: ast.Node.ClassDef) CodegenError!void {
    try self.class_names.put(class.name, {});
    var buf = std.ArrayList(u8){};
    try buf.writer(self.allocator).print("const {s} = struct {{", .{class.name});
    try self.emit(try buf.toOwnedSlice(self.allocator));
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
                                            try field_buf.writer(self.allocator).print("{s}: i64,", .{attr.attr});
                                            try self.emit(try field_buf.toOwnedSlice(self.allocator));
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
        try buf.writer(self.allocator).writeAll("pub fn init(");

        for (init_func.args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg.name, "self")) continue;
            if (i > 1) try buf.writer(self.allocator).writeAll(", ");
            try buf.writer(self.allocator).print("{s}: i64", .{arg.name});
        }

        try buf.writer(self.allocator).print(") {s} {{", .{class.name});
        try self.emit(try buf.toOwnedSlice(self.allocator));
        self.indent();

        buf = std.ArrayList(u8){};
        try buf.writer(self.allocator).print("return {s}{{", .{class.name});
        try self.emit(try buf.toOwnedSlice(self.allocator));
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
                                            try buf.writer(self.allocator).print(".{s} = {s},", .{ attr.attr, value_result.code });
                                            try self.emit(try buf.toOwnedSlice(self.allocator));
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
        try buf.writer(self.allocator).print("pub fn {s}(", .{method.name});

        for (method.args, 0..) |arg, i| {
            if (i > 0) try buf.writer(self.allocator).writeAll(", ");
            if (std.mem.eql(u8, arg.name, "self")) {
                try buf.writer(self.allocator).print("self: *{s}", .{class.name});
            } else {
                try buf.writer(self.allocator).print("{s}: i64", .{arg.name});
            }
        }

        try buf.writer(self.allocator).writeAll(") void {");
        try self.emit(try buf.toOwnedSlice(self.allocator));
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

pub fn visitMethodCall(self: *ZigCodeGenerator, attr: ast.Node.Attribute, args: []ast.Node) CodegenError!ExprResult {
    const obj_result = try expressions.visitExpr(self,attr.value.*);
    const method_name = attr.attr;
    var buf = std.ArrayList(u8){};

    // String methods
    if (std.mem.eql(u8, method_name, "upper")) {
        try buf.writer(self.allocator).print("runtime.PyString.upper(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "lower")) {
        try buf.writer(self.allocator).print("runtime.PyString.lower(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "strip")) {
        try buf.writer(self.allocator).print("runtime.PyString.strip(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "lstrip")) {
        try buf.writer(self.allocator).print("runtime.PyString.lstrip(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "rstrip")) {
        try buf.writer(self.allocator).print("runtime.PyString.rstrip(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "split")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyString.split(allocator, {s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "replace")) {
        if (args.len != 2) return error.InvalidArguments;
        const arg1_result = try expressions.visitExpr(self,args[0]);
        const arg2_result = try expressions.visitExpr(self,args[1]);
        try buf.writer(self.allocator).print("runtime.PyString.replace(allocator, {s}, {s}, {s})", .{ obj_result.code, arg1_result.code, arg2_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "capitalize")) {
        try buf.writer(self.allocator).print("runtime.PyString.capitalize(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "swapcase")) {
        try buf.writer(self.allocator).print("runtime.PyString.swapcase(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "title")) {
        try buf.writer(self.allocator).print("runtime.PyString.title(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "center")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyString.center(allocator, {s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "join")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyString.join(allocator, {s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "startswith")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyString.startswith({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "endswith")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyString.endswith({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "isdigit")) {
        try buf.writer(self.allocator).print("runtime.PyString.isdigit({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "isalpha")) {
        try buf.writer(self.allocator).print("runtime.PyString.isalpha({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "find")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyString.find({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    }
    // List methods
    else if (std.mem.eql(u8, method_name, "append")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyList.append({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "pop")) {
        try buf.writer(self.allocator).print("runtime.PyList.pop(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "extend")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyList.extend({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "reverse")) {
        try buf.writer(self.allocator).print("runtime.PyList.reverse({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "remove")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyList.remove(allocator, {s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "count")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyList.count({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "index")) {
        if (args.len != 1) return error.InvalidArguments;
        const arg_result = try expressions.visitExpr(self,args[0]);
        try buf.writer(self.allocator).print("runtime.PyList.index({s}, {s})", .{ obj_result.code, arg_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "insert")) {
        if (args.len != 2) return error.InvalidArguments;
        const arg1_result = try expressions.visitExpr(self,args[0]);
        const arg2_result = try expressions.visitExpr(self,args[1]);
        try buf.writer(self.allocator).print("runtime.PyList.insert(allocator, {s}, {s}, {s})", .{ obj_result.code, arg1_result.code, arg2_result.code });
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else if (std.mem.eql(u8, method_name, "clear")) {
        try buf.writer(self.allocator).print("runtime.PyList.clear(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "sort")) {
        try buf.writer(self.allocator).print("runtime.PyList.sort({s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = false };
    } else if (std.mem.eql(u8, method_name, "copy")) {
        try buf.writer(self.allocator).print("runtime.PyList.copy(allocator, {s})", .{obj_result.code});
        return ExprResult{ .code = try buf.toOwnedSlice(self.allocator), .needs_try = true };
    } else {
        return error.UnsupportedMethod;
    }
}
