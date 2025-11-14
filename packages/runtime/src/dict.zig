/// Python dict type implementation
/// Separated from runtime.zig for better code organization
const std = @import("std");
const runtime = @import("runtime.zig");

/// Python dict type (simplified - using StringHashMap)
pub const PyDict = struct {
    map: std.StringHashMap(*runtime.PyObject),

    pub fn create(allocator: std.mem.Allocator) !*runtime.PyObject {
        const obj = try allocator.create(runtime.PyObject);
        const dict_data = try allocator.create(PyDict);
        dict_data.map = std.StringHashMap(*runtime.PyObject).init(allocator);

        obj.* = runtime.PyObject{
            .ref_count = 1,
            .type_id = .dict,
            .data = dict_data,
        };
        return obj;
    }

    pub fn set(obj: *runtime.PyObject, key: []const u8, value: *runtime.PyObject) !void {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        try data.map.put(key, value);
        // Note: Caller transfers ownership, no incref needed
    }

    pub fn get(obj: *runtime.PyObject, key: []const u8) ?*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        if (data.map.get(key)) |value| {
            runtime.incref(value); // Incref before returning - caller owns reference
            return value;
        }
        return null;
    }

    pub fn contains(obj: *runtime.PyObject, key: []const u8) bool {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        return data.map.contains(key);
    }

    pub fn len(obj: *runtime.PyObject) usize {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        return data.map.count();
    }

    pub fn keys(allocator: std.mem.Allocator, obj: *runtime.PyObject) !*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));

        // Create list to hold keys
        const result = try runtime.PyList.create(allocator);

        // Add all keys as PyString objects
        var iterator = data.map.keyIterator();
        while (iterator.next()) |key| {
            const key_obj = try runtime.PyString.create(allocator, key.*);
            try runtime.PyList.append(result, key_obj);
            // Note: Ownership transferred to list, no decref needed
        }

        return result;
    }

    pub fn values(allocator: std.mem.Allocator, obj: *runtime.PyObject) !*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));

        // Create list to hold values
        const result = try runtime.PyList.create(allocator);

        // Add all values (incref since we're sharing between containers)
        var iterator = data.map.valueIterator();
        while (iterator.next()) |value| {
            runtime.incref(value.*);
            try runtime.PyList.append(result, value.*);
        }

        return result;
    }

    pub fn getWithDefault(allocator: std.mem.Allocator, obj: *runtime.PyObject, key: []const u8, default: *runtime.PyObject) *runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        _ = allocator;
        if (data.map.get(key)) |found| {
            // Found in dict - incref and return (caller must decref)
            runtime.incref(found);
            return found;
        } else {
            // Not found - incref default before returning (caller must decref)
            runtime.incref(default);
            return default;
        }
    }

    pub fn get_method(allocator: std.mem.Allocator, obj: *runtime.PyObject, key: *runtime.PyObject, default: *runtime.PyObject) *runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        std.debug.assert(key.type_id == .string);
        const key_data: *runtime.PyString = @ptrCast(@alignCast(key.data));
        const result = getWithDefault(allocator, obj, key_data.data, default);
        // Note: Don't decref key here - caller owns it and will decref via defer
        return result;
    }

    pub fn pop(allocator: std.mem.Allocator, obj: *runtime.PyObject, key: []const u8) ?*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        _ = allocator;

        // Get value before removing
        if (data.map.fetchRemove(key)) |entry| {
            return entry.value;
        }
        return null;
    }

    pub fn pop_method(allocator: std.mem.Allocator, obj: *runtime.PyObject, key: *runtime.PyObject) ?*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        std.debug.assert(key.type_id == .string);
        const key_data: *runtime.PyString = @ptrCast(@alignCast(key.data));
        return pop(allocator, obj, key_data.data);
    }

    pub fn clear(allocator: std.mem.Allocator, obj: *runtime.PyObject) void {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        const alloc = allocator; // Use passed allocator for consistency
        _ = alloc;

        // Decref all values before clearing
        var iterator = data.map.valueIterator();
        while (iterator.next()) |value| {
            runtime.decref(value.*, data.map.allocator);
        }

        data.map.clearAndFree();
    }

    pub fn items(allocator: std.mem.Allocator, obj: *runtime.PyObject) !*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));

        // Create list to hold items
        const result = try runtime.PyList.create(allocator);

        // Add all (key, value) pairs as 2-element tuples
        var iterator = data.map.iterator();
        while (iterator.next()) |entry| {
            const pair = try runtime.PyTuple.create(allocator, 2);
            const key_obj = try runtime.PyString.create(allocator, entry.key_ptr.*);
            runtime.PyTuple.setItem(pair, 0, key_obj);
            // Note: Ownership transferred to tuple, no decref needed
            runtime.incref(entry.value_ptr.*); // Incref value since we're sharing it
            runtime.PyTuple.setItem(pair, 1, entry.value_ptr.*);
            try runtime.PyList.append(result, pair);
            // Note: Ownership transferred to list, no decref needed
        }

        return result;
    }

    pub fn update(obj: *runtime.PyObject, other: *runtime.PyObject) !void {
        std.debug.assert(obj.type_id == .dict);
        std.debug.assert(other.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        const other_data: *PyDict = @ptrCast(@alignCast(other.data));

        // Copy all entries from other dict
        var iterator = other_data.map.iterator();
        while (iterator.next()) |entry| {
            try data.map.put(entry.key_ptr.*, entry.value_ptr.*);
            runtime.incref(entry.value_ptr.*);
        }
    }

    pub fn copy(allocator: std.mem.Allocator, obj: *runtime.PyObject) !*runtime.PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));

        const new_dict = try create(allocator);
        const new_data: *PyDict = @ptrCast(@alignCast(new_dict.data));

        // Copy all entries
        var iterator = data.map.iterator();
        while (iterator.next()) |entry| {
            try new_data.map.put(entry.key_ptr.*, entry.value_ptr.*);
            runtime.incref(entry.value_ptr.*);
        }

        return new_dict;
    }
};
