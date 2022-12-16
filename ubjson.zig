const std = @import("std");
const testing = std.testing;

const u8Stream = std.io.FixedBufferStream([]const u8);

const Error = error{
    UnexpectedSymbol,
    TypeMismatch,
    MissingKey,
    MissingContainerCount,
    CountTooLarge,
};

const Object = std.StringHashMapUnmanaged(UBJSON);
const List = std.ArrayListUnmanaged(UBJSON);
pub const UBJSONKind = enum {
    null,
    bool,
    int,
    f32,
    f64,
    string,
    buffer,
    array,
    object,
};

fn KindType(comptime kind: UBJSONKind) type {
    return switch (kind) {
        .null => void,
        .bool => bool,
        .int => i64,
        .f32 => f32,
        .f64 => f64,
        .string => []const u8,
        .buffer => []const u8,
        .array => List,
        .object => Object,
    };
}

pub const UBJSON = union(UBJSONKind) {
    null,
    bool: bool,
    int: i64,
    f32: f32,
    f64: f64,
    string: []const u8,
    buffer: []const u8,
    array: List,
    object: Object,

    pub fn initValue(v: anytype) UBJSON {
        const T = @TypeOf(v);
        return switch (T) {
            void => UBJSON{ .null = {} },
            bool => UBJSON{ .bool = v },
            comptime_int, u8, i8, i16, i32, i64, isize, usize => UBJSON{ .int = @intCast(i64, v) },
            f32 => UBJSON{ .f32 = v },
            f64 => UBJSON{ .f64 = v },
            else => @compileError("Incompatible type"),
        };
    }
    pub fn initString(alloc: std.mem.Allocator, v: []const u8) !UBJSON {
        return UBJSON{ .string = try alloc.dupe(u8, v) };
    }
    pub fn initBuffer(alloc: std.mem.Allocator, v: []const u8) !UBJSON {
        return UBJSON{ .buffer = try alloc.dupe(u8, v) };
    }

    pub fn getValue(this: *const @This(), comptime kind: UBJSONKind) !KindType(kind) {
        const T = KindType(kind);
        switch (this.*) {
            inline else => |v| {
                if (@TypeOf(v) != T) {
                    return Error.TypeMismatch;
                }
                return v;
            },
        }
    }

    pub fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        switch (this.*) {
            UBJSON.string, UBJSON.buffer => |v| {
                alloc.free(v);
            },
            UBJSON.array => |*arr| {
                for (arr.items) |*el| {
                    el.deinit(alloc);
                }
                arr.deinit(alloc);
            },
            UBJSON.object => |*obj| {
                var valueIter = obj.valueIterator();
                while (valueIter.next()) |*value| {
                    value.*.deinit(alloc);
                }
                var keyIter = obj.keyIterator();
                while (keyIter.next()) |key| {
                    alloc.free(key.*);
                }
                obj.deinit(alloc);
            },
            else => {},
        }
    }

    pub fn serialize(this: *const @This(), writer: anytype) !void {
        switch (this.*) {
            UBJSON.null => {
                try writer.writeByte('Z');
            },
            UBJSON.bool => |b| {
                if (b) {
                    try writer.writeByte('T');
                } else {
                    try writer.writeByte('F');
                }
            },
            UBJSON.int => |n| {
                try serializeInt(writer, n);
            },
            UBJSON.f32 => |f| {
                try writer.writeByte('d');
                try writer.writeAll(&std.mem.toBytes(f));
            },
            UBJSON.f64 => |f| {
                try writer.writeByte('D');
                try writer.writeAll(&std.mem.toBytes(f));
            },
            UBJSON.string => |str| {
                try writer.writeByte('S');
                try serializeStringNoSym(writer, str);
            },
            UBJSON.buffer => |buf| {
                try writer.writeAll("[$U#");
                try serializeInt(writer, @intCast(i64, buf.len));
                try writer.writeAll(buf);
            },
            UBJSON.array => |*arr| {
                try writer.writeByte('[');
                for (arr.items) |el| {
                    try el.serialize(writer);
                }
                try writer.writeByte(']');
            },
            UBJSON.object => |*obj| {
                try writer.writeByte('{');
                var keyIter = obj.keyIterator();
                while (keyIter.next()) |key| {
                    try serializeStringNoSym(writer, key.*);
                    try obj.get(key.*).?.serialize(writer);
                }
                try writer.writeByte('}');
            },
        }
    }

    pub fn serializeAlloc(this: *const @This(), alloc: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(alloc);
        try this.serialize(list.writer());
        return list.toOwnedSlice();
    }

    pub fn getKey(this: *const @This(), key: []const u8) Error!UBJSON {
        if (this.* != .object) {
            return Error.TypeMismatch;
        }
        return this.object.get(key) orelse Error.MissingKey;
    }
    pub fn getKeyValue(this: *const @This(), key: []const u8, comptime kind: UBJSONKind) Error!KindType(kind) {
        return (try this.getKey(key)).getValue(kind);
    }

    pub fn putKey(this: *@This(), alloc: std.mem.Allocator, key: []const u8, value: UBJSON) !void {
        if (this.* != .object) {
            return Error.TypeMismatch;
        }
        if (this.object.contains(key)) {
            this.object.getPtr(key).?.* = value;
        } else {
            try this.object.put(alloc, try alloc.dupe(u8, key), value);
        }
    }

    pub fn format(this: *const @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const tabs = options.width orelse 0;
        switch (this.*) {
            UBJSON.null => try writer.writeAll("<null>"),
            UBJSON.bool => |v| if (v) try writer.writeAll("true") else try writer.writeAll("false"),
            UBJSON.int => |v| try std.fmt.formatInt(v, 10, std.fmt.Case.lower, .{}, writer),
            inline UBJSON.f32, UBJSON.f64 => |v| try std.fmt.formatFloatDecimal(v, .{}, writer),
            inline UBJSON.string, UBJSON.buffer => |v| try writer.writeAll(v),
            UBJSON.array => |v| {
                try writer.writeAll("[\n");
                var i: usize = 0;
                while (i < v.items.len) : (i += 1) {
                    try writer.writeByteNTimes(' ', (tabs + 1) * 2);
                    try v.items[i].format(fmt, .{ .width = tabs + 1 }, writer);
                }
                try writer.writeByteNTimes(' ', tabs * 2);
                try writer.writeByte(']');
            },
            UBJSON.object => |v| {
                try writer.writeAll("{\n");
                var iter = v.keyIterator(); // TODO: sort keys
                while (iter.next()) |key| {
                    try writer.writeByteNTimes(' ', (tabs + 1) * 2);
                    try writer.writeAll(key.*);
                    try writer.writeAll(": ");
                    try v.get(key.*).?.format(fmt, .{ .width = tabs + 1 }, writer);
                }
                try writer.writeByteNTimes(' ', tabs * 2);
                try writer.writeByte('}');
            },
        }
        try writer.writeByte('\n');
    }
};

fn nextNonNoop(reader: anytype) !u8 {
    var sym = try reader.readByte();
    while (sym == 'N') {
        sym = try reader.readByte();
    }
    return sym;
}

fn nextNonNoopConsumeIf(stream: *u8Stream, sym: u8) !bool {
    var pos = try stream.getPos();
    const nsym = try nextNonNoop(stream.reader());
    if (nsym == sym) {
        return true;
    } else {
        try stream.seekTo(pos);
        return false;
    }
}

fn parseInt(reader: anytype) !i64 {
    const sym = try nextNonNoop(reader);
    switch (sym) {
        'i', 'U', 'C' => return try reader.readByte(),
        'I' => return try reader.readIntBig(i16),
        'l' => return try reader.readIntBig(i32),
        'L' => return try reader.readIntBig(i64),
        else => return error.UnexpectedSymbol,
    }
}

fn parseStringNoSym(alloc: std.mem.Allocator, stream: *u8Stream) ![]const u8 {
    const len = @intCast(u32, try parseInt(stream.reader()));
    const slice = alloc.dupe(u8, stream.buffer[try stream.getPos() .. try stream.getPos() + len]);
    try stream.seekBy(@intCast(i64, len));
    return slice;
}

fn serializeInt(writer: anytype, n: i64) !void {
    // TODO: proper types
    try writer.writeByte('L');
    try writer.writeIntBig(i64, n);
}

fn serializeStringNoSym(writer: anytype, str: []const u8) !void {
    try serializeInt(writer, @intCast(i64, str.len));
    _ = try writer.write(str);
}

fn parseValue(alloc: std.mem.Allocator, stream: *u8Stream, sym: u8) !UBJSON {
    var reader = stream.reader();
    switch (sym) {
        'Z' => return UBJSON{ .null = {} },
        'T' => return UBJSON{ .bool = true },
        'F' => return UBJSON{ .bool = false },
        'i', 'U', 'C' => return UBJSON{ .int = try reader.readByte() },
        'I' => return UBJSON{ .int = try reader.readIntBig(i16) },
        'l' => return UBJSON{ .int = try reader.readIntBig(i32) },
        'L' => return UBJSON{ .int = try reader.readIntBig(i64) },
        'd' => {
            const bytes = try reader.readBytesNoEof(4);
            return UBJSON{ .f32 = std.mem.bytesAsValue(f32, &bytes).* };
        },
        'D' => {
            const bytes = try reader.readBytesNoEof(8);
            return UBJSON{ .f64 = std.mem.bytesAsValue(f64, &bytes).* };
        },
        'S', 'H' => return UBJSON{ .string = try parseStringNoSym(alloc, stream) },
        '[' => {
            var valueKind: ?u8 = null;
            if (try nextNonNoopConsumeIf(stream, '$')) {
                valueKind = try reader.readByte();
            }
            var count: ?usize = null;
            if (try nextNonNoopConsumeIf(stream, '#')) {
                count = @intCast(usize, try parseInt(reader));
            } else if (valueKind != null) {
                return Error.MissingContainerCount;
            }

            if (valueKind != null and valueKind.? == 'U') { // TODO: flag to disable this behavior
                if (count.? > stream.buffer.len) {
                    return Error.CountTooLarge;
                }
                var array = try alloc.alloc(u8, count.?);
                errdefer alloc.free(array);
                try reader.readNoEof(array);
                return UBJSON{ .buffer = array };
            } else {
                var list = List{};
                errdefer list.deinit(alloc);
                var i: usize = 0;
                while (count == null or i < count.?) : (i += 1) {
                    if (count == null and try nextNonNoopConsumeIf(stream, ']')) {
                        break;
                    }
                    if (valueKind == null) {
                        const value = try parse(alloc, stream);
                        try list.append(alloc, value);
                    } else {
                        const value = try parseValue(alloc, stream, valueKind.?);
                        try list.append(alloc, value);
                    }
                }
                return UBJSON{ .array = list };
            }
        },
        '{' => {
            var valueKind: ?u8 = null;
            if (try nextNonNoopConsumeIf(stream, '$')) {
                valueKind = try stream.reader().readByte();
            }
            var count: ?usize = null;
            if (try nextNonNoopConsumeIf(stream, '#')) {
                count = @intCast(usize, try parseInt(reader));
            } else if (valueKind != null) {
                return Error.MissingContainerCount;
            }
            var map = Object{};
            errdefer map.deinit(alloc);
            var i: usize = 0;
            while (count == null or i < count.?) : (i += 1) {
                if (count == null and try nextNonNoopConsumeIf(stream, '}')) {
                    break;
                }
                const key = try parseStringNoSym(alloc, stream);
                if (valueKind == null) {
                    const value = try parse(alloc, stream);
                    try map.put(alloc, key, value);
                } else {
                    const value = try parseValue(alloc, stream, valueKind.?);
                    try map.put(alloc, key, value);
                }
            }
            return UBJSON{ .object = map };
        },
        else => return error.UnexpectedSymbol,
    }
}

pub fn parse(alloc: std.mem.Allocator, stream: *u8Stream) !UBJSON {
    const sym = try nextNonNoop(stream.reader());
    return parseValue(alloc, stream, sym);
}

pub fn parseBuf(alloc: std.mem.Allocator, buf: []const u8) !UBJSON {
    var stream = std.io.fixedBufferStream(buf);
    return parse(alloc, &stream);
}

test "basic parsing" {
    const input = "{i\x07numbers[i\x01i\x02i\x03]U\x05helloSi\x05world}";
    var output = try parseBuf(testing.allocator, input);
    defer output.deinit(testing.allocator);
    try testing.expect(output == .object);
    try testing.expectEqualSlices(u8, output.object.get("hello").?.string, "world");
    const numbers = output.object.get("numbers").?.array;
    try testing.expectEqual(numbers.items.len, 3);
    try testing.expectEqual(numbers.items[0].int, 1);
    try testing.expectEqual(numbers.items[1].int, 2);
    try testing.expectEqual(numbers.items[2].int, 3);
}

test "all types" {
    const FORMATTED =
    \\[
    \\  <null>
    \\  true
    \\  false
    \\  {
    \\    int: 1234
    \\    f32: 12.34000015258789
    \\    string: foo
    \\    buffer: bar
    \\    f64: 12.34
    \\  }
    \\]
    \\
    ;

    // Create structure
    var json = UBJSON{ .array = .{} };
    defer json.deinit(testing.allocator);
    try json.array.append(testing.allocator, .{ .null = {} });
    try json.array.append(testing.allocator, .{ .bool = true });
    try json.array.append(testing.allocator, .{ .bool = false });
    var obj = UBJSON{ .object = .{} };
    try obj.putKey(testing.allocator, "int", UBJSON.initValue(1234) );
    try obj.putKey(testing.allocator, "f32", UBJSON.initValue(@as(f32, 12.34)));
    try obj.putKey(testing.allocator, "f64", UBJSON.initValue(@as(f64, 12.34)));
    try obj.putKey(testing.allocator, "string", try UBJSON.initString(testing.allocator, "foo"));
    try obj.putKey(testing.allocator, "buffer", try UBJSON.initBuffer(testing.allocator, "bar"));
    try json.array.append(testing.allocator, obj);

    // Serialize and deserialize
    var serialized = try json.serializeAlloc(testing.allocator);
    defer testing.allocator.free(serialized);
    var parsed = try parseBuf(testing.allocator, serialized);
    defer parsed.deinit(testing.allocator);

    // Compare with string
    const formatted = try std.fmt.allocPrint(testing.allocator, "{}", .{parsed});
    defer testing.allocator.free(formatted);
    try testing.expectEqualStrings(FORMATTED, formatted);
}

test "real world data" {
    // Slippi handshake
    const input = "\x7B\x69\x04\x74\x79\x70\x65\x55\x01\x69\x07\x70\x61\x79\x6C\x6F\x61\x64\x7B\x69\x04\x6E\x69\x63\x6B\x53\x69\x03\x4A\x57\x51\x69\x11\x6E\x69\x6E\x74\x65\x6E\x64\x6F\x6E\x74\x56\x65\x72\x73\x69\x6F\x6E\x53\x69\x06\x31\x2E\x31\x30\x2E\x32\x69\x0B\x63\x6C\x69\x65\x6E\x74\x54\x6F\x6B\x65\x6E\x5B\x24\x55\x23\x69\x04\xFE\x9E\x57\x74\x69\x03\x70\x6F\x73\x5B\x24\x55\x23\x69\x08\x00\x00\x00\x00\x00\x0A\x7C\xCF\x7D\x7D";

    var output = try parseBuf(testing.allocator, input);
    defer output.deinit(testing.allocator);

    const packetType = try output.getKeyValue("type", .int);
    std.log.debug("Type: {}", .{packetType});
    const payload = try output.getKey("payload");
    const nick = try payload.getKeyValue("nick", .string);
    const ninver = try payload.getKeyValue("nintendontVersion", .string);
    const token = try payload.getKeyValue("clientToken", .buffer);
    const cursor = try payload.getKeyValue("pos", .buffer);
    std.log.debug("Nick: {s}, NinVer: {s}, Token: {d}, Cursor: {d}", .{ nick, ninver, token, cursor });
}
