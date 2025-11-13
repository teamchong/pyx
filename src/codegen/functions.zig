const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const statements = @import("statements.zig");

const ZigCodeGenerator = codegen.ZigCodeGenerator;
const ExprResult = codegen.ExprResult;
const CodegenError = codegen.CodegenError;

/// Generate code for function definition
pub fn visitFunctionDef(self: *ZigCodeGenerator, func: ast.Node.FunctionDef) CodegenError!void {
    // For now, generate simple functions with i64 parameters and return type
    // This handles common cases like fibonacci(n: int) -> int

    var buf = std.ArrayList(u8){};

    // Start function signature
    try buf.writer(self.allocator).print("fn {s}(", .{func.name});

    // Add parameters - assume i64 for now
    for (func.args, 0..) |arg, i| {
        if (i > 0) {
            try buf.writer(self.allocator).writeAll(", ");
        }
        try buf.writer(self.allocator).print("{s}: i64", .{arg.name});
    }

    // Add allocator parameter if needed
    if (self.needs_allocator) {
        if (func.args.len > 0) {
            try buf.writer(self.allocator).writeAll(", ");
        }
        try buf.writer(self.allocator).writeAll("allocator: std.mem.Allocator");
    }

    // Close signature - assume i64 return type for now
    try buf.writer(self.allocator).writeAll(") i64 {");

    try self.emitOwned(try buf.toOwnedSlice(self.allocator));
    self.indent();

    // Generate function body
    for (func.body) |stmt| {
        try statements.visitNode(self, stmt);
    }

    self.dedent();
    try self.emit("}");
}

/// Generate code for user-defined function call
pub fn visitUserFunctionCall(self: *ZigCodeGenerator, func_name: []const u8, args: []ast.Node) CodegenError!ExprResult {
    var buf = std.ArrayList(u8){};

    // Generate function call: func_name(arg1, arg2, ...)
    try buf.writer(self.allocator).print("{s}(", .{func_name});

    // Add arguments
    for (args, 0..) |arg, i| {
        if (i > 0) {
            try buf.writer(self.allocator).writeAll(", ");
        }
        const arg_result = try self.visitExpr(arg);
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
