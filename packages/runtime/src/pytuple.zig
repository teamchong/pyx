/// PyTuple implementation - Python tuple type (immutable sequence)
const std = @import("std");
const runtime = @import("runtime.zig");

const PyObject = runtime.PyObject;
const incref = runtime.incref;
const PythonError = runtime.PythonError;

/// Python tuple type (immutable sequence)
pub const PyTuple = struct {
    items: []*PyObject,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, size: usize) !*PyObject {
        const obj = try allocator.create(PyObject);
        const tuple_data = try allocator.create(PyTuple);

        // Allocate fixed-size array for items
        const items = try allocator.alloc(*PyObject, size);

        tuple_data.* = PyTuple{
            .items = items,
            .allocator = allocator,
        };

        obj.* = PyObject{
            .ref_count = 1,
            .type_id = .tuple,
            .data = tuple_data,
        };
        return obj;
    }

    pub fn fromSlice(allocator: std.mem.Allocator, values: []const PyObject.Value) !*PyObject {
        const obj = try create(allocator, values.len);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));

        for (values, 0..) |value, i| {
            const item = try runtime.PyInt.create(allocator, value.int);
            data.items[i] = item;
        }

        return obj;
    }

    pub fn setItem(obj: *PyObject, idx: usize, item: *PyObject) void {
        std.debug.assert(obj.type_id == .tuple);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));
        std.debug.assert(idx < data.items.len);
        data.items[idx] = item;
        // Note: Caller transfers ownership, no incref needed
    }

    pub fn getItem(obj: *PyObject, idx: usize) PythonError!*PyObject {
        std.debug.assert(obj.type_id == .tuple);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));
        if (idx >= data.items.len) {
            return PythonError.IndexError;
        }
        const item = data.items[idx];
        incref(item);
        return item;
    }

    pub fn len(obj: *PyObject) usize {
        std.debug.assert(obj.type_id == .tuple);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));
        return data.items.len;
    }

    pub fn len_method(obj: *PyObject) i64 {
        std.debug.assert(obj.type_id == .tuple);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));
        return @intCast(data.items.len);
    }

    pub fn contains(obj: *PyObject, value: *PyObject) bool {
        std.debug.assert(obj.type_id == .tuple);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));

        // Check each item in the tuple
        for (data.items) |item| {
            // For now, only support comparing integers
            if (item.type_id == .int and value.type_id == .int) {
                const item_data: *runtime.PyInt = @ptrCast(@alignCast(item.data));
                const value_data: *runtime.PyInt = @ptrCast(@alignCast(value.data));
                if (item_data.value == value_data.value) {
                    return true;
                }
            }
            // Could add string comparison here later
        }
        return false;
    }

    /// Print tuple in Python format: (1, 2, 3)
    pub fn print(obj: *PyObject) void {
        std.debug.assert(obj.type_id == .tuple);
        const data: *PyTuple = @ptrCast(@alignCast(obj.data));

        std.debug.print("(", .{});
        for (data.items, 0..) |item, i| {
            switch (item.type_id) {
                .int => {
                    const int_data: *runtime.PyInt = @ptrCast(@alignCast(item.data));
                    std.debug.print("{d}", .{int_data.value});
                },
                .string => {
                    const str_data: *runtime.PyString = @ptrCast(@alignCast(item.data));
                    std.debug.print("'{s}'", .{str_data.data});
                },
                else => std.debug.print("{any}", .{item}),
            }
            if (i < data.items.len - 1) {
                std.debug.print(", ", .{});
            }
        }
        std.debug.print(")", .{});
    }
};
