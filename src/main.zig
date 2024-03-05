const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub fn Parser(comptime Value: type, comptime Reader: type) type {
    return struct {
        const Self = @This();
        pub const VTable = struct { _parse: *const fn (ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?Value };
        ptr: *anyopaque,
        table: VTable,

        /// Used internally, but exposed. If you call this directly some things may never be able to be freed.
        pub fn parseLeaky(self: *const Self, allocator: Allocator, src: *Reader) anyerror!?Value {
            return self.table._parse(self.ptr, allocator, src);
        }
        pub fn parseOrDieLeaky(self: *const Self, allocator: Allocator, src: *Reader) anyerror!Value {
            return try self.parseLeaky(allocator, src) orelse return error.ParseFailed;
        }
        pub fn parse(self: *const Self, allocator: Allocator, src: *Reader) anyerror!?Parsed(Value) {
            var parsed = Parsed(Value){ .arena = try allocator.create(std.heap.ArenaAllocator), .value = undefined };
            errdefer allocator.destroy(parsed.arena);
            parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer parsed.arena.deinit();

            parsed.value = try self.parseLeaky(parsed.arena.allocator(), src) orelse {
                parsed.arena.deinit();
                allocator.destroy(parsed.arena);
                return null;
            };
            return parsed;
        }
        // Returns an error instead of null
        pub fn parseOrDie(self: *const Self, allocator: Allocator, src: *Reader) anyerror!Parsed(Value) {
            return try self.parse(allocator, src) orelse return error.ParseFailed;
        }
        pub fn voided(self: Self) Voided(Value, Reader) {
            return Voided(Value, Reader).init(self);
        }
    };
}

pub fn Parsed(comptime Value: type) type {
    return struct {
        const Self = @This();

        arena: *std.heap.ArenaAllocator,
        value: Value,

        // Frees all memory allocated while parsing self.value.
        pub fn deinit(self: *const Self) void {
            const alloc = self.arena.child_allocator;
            self.arena.deinit();
            alloc.destroy(self.arena);
        }
    };
}

pub fn Literal(comptime Reader: type) type {
    const ThisParser = Parser([]u8, Reader);
    return struct {
        const Self = @This();
        const vtable: ThisParser.VTable = .{ ._parse = parse };

        want: []const u8,
        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?[]u8 {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const buf = try allocator.alloc(u8, self.want.len);
            errdefer allocator.free(buf);
            const read = try src.reader().readAll(buf);
            if (read < self.want.len or !std.mem.eql(u8, buf, self.want)) {
                try src.seekableStream().seekBy(-@as(i64, @intCast(read)));

                allocator.free(buf);
                return null;
            }
            return buf;
        }

        pub fn init(want: []const u8) Self {
            return .{ .want = want };
        }
        pub fn parser(self: *Self) ThisParser {
            return .{ .ptr = self, .table = vtable };
        }
    };
}

pub fn Voided(comptime Value: type, comptime Reader: type) type {
    return struct {
        child_parser: Parser(Value, Reader),

        const Self = @This();
        const vtable: Parser(void, Reader).VTable = .{ ._parse = parse };

        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?void {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const res = try self.child_parser.parseLeaky(allocator, src);
            if (res) |_| {
                return;
            }
            return null;
        }
        pub fn init(child: Parser(Value, Reader)) Self {
            return .{ .child_parser = child };
        }
        pub fn parser(self: *Self) Parser(void, Reader) {
            return .{ .ptr = self, .table = vtable };
        }
    };
}

// TODO: maybe make one like this with an automatic union?
/// Returns the result of the first success, or null otherwise.
/// Will return an error if the buffer was partially consumed.
pub fn OneOf(comptime Value: type, comptime Reader: type) type {
    return struct {
        parsers: []Parser(Value, Reader),

        const Self = @This();
        const vtable: Parser(Value, Reader).VTable = .{ ._parse = parse };

        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?Value {
            const self: *Self = @alignCast(@ptrCast(ctx));
            for (self.parsers) |p| {
                const res = try p.parseLeaky(allocator, src);
                if (res) |r| return r;
            }
            return null;
        }

        pub fn init(children: []Parser(Value, Reader)) Self {
            return Self{ .parsers = children };
        }
        pub fn parser(self: *Self) Parser(Value, Reader) {
            return .{ .ptr = self, .table = vtable };
        }
    };
}

/// Returns the result of a sequence of parses, done one after another
/// Errors with "error.PartiallyConsumed" if a parser returns null.
pub fn Sequence(comptime Tuple: type, comptime Reader: type) type {
    const info = @typeInfo(Tuple).Struct;
    if (!info.is_tuple) @compileError("Tuple must be a tuple struct");
    comptime var new_fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        var new_field: std.builtin.Type.StructField = field;
        new_field.default_value = null;
        if (new_field.is_comptime)
            @compileError("Tuple can't have any comptime fields.");
        new_field.type = Parser(field.type, Reader);
        new_fields[i] = new_field;
    }
    const ParserTuple = @Type(.{ .Struct = .{ .is_tuple = true, .fields = &new_fields, .decls = &.{}, .layout = .Auto } });
    return struct {
        parsers: ParserTuple,

        const Self = @This();

        pub fn init(parsers: ParserTuple) Self {
            return .{ .parsers = parsers };
        }

        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?Tuple {
            const self: *Self = @alignCast(@ptrCast(ctx));
            var res: Tuple = undefined;
            inline for (self.parsers, 0..) |p, i| {
                const parsed = try p.parseLeaky(allocator, src);
                if (parsed) |pp| {
                    res[i] = pp;
                } else {
                    return error.PartiallyConsumed;
                }
            }
            return res;
        }

        pub fn parser(self: *Self) Parser(Tuple, Reader) {
            return .{ .ptr = self, .table = .{ ._parse = parse } };
        }
    };
}

pub fn AnyChar(comptime Reader: type) type {
    return struct {
        const Self = @This();
        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?u8 {
            _ = ctx;
            _ = allocator;
            const res = try src.reader().readByte();
            return res;
        }

        pub fn parser() Parser(u8, Reader) {
            return .{ .ptr = undefined, .table = .{ ._parse = &parse } };
        }
    };
}

pub fn Char(comptime Reader: type) type {
    return struct {
        byte: u8,

        const Self = @This();

        pub fn init(byte: u8) Self {
            return Self{ .byte = byte };
        }
        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?u8 {
            _ = allocator;
            const self: *Self = @alignCast(@ptrCast(ctx));
            const res = try src.reader().readByte();
            if (res == self.byte) {
                return res;
            }
            src.seekableStream().seekBy(-1);
            return null;
        }
        pub fn parser(self: *Self) Parser(u8, Reader) {
            return .{ .ptr = self, .table = .{ ._parse = &parse } };
        }
    };
}

// unsure if whereFn should be in the param list or not
pub fn CharWhere(comptime Context: type, comptime Reader: type, comptime whereFn: fn (ctx: Context, char: u8) bool) type {
    return struct {
        context: Context,

        const Self = @This();

        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?u8 {
            _ = allocator;
            const self: *Self = @alignCast(@ptrCast(ctx));
            const res = try src.reader().readByte();
            if (whereFn(self.context, res)) {
                return res;
            }
            src.seekableStream().seekBy(-1);
            return null;
        }
    };
}
/// Errors if many_of returns null after 1 successful parse
pub fn ManyTill(comptime ManyVal: type, comptime TillVal: type, comptime Reader: type) type {
    return struct {
        many_of: Parser(ManyVal, Reader),
        til: Parser(TillVal, Reader),

        const Self = @This();

        pub fn init(many: Parser(ManyVal, Reader), til: Parser(TillVal, Reader)) Self {
            return .{ .many_of = many, .til = til };
        }
        // u free the list nerd
        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?[]ManyVal {
            const self: *Self = @alignCast(@ptrCast(ctx));
            var list = std.ArrayList(ManyVal).init(allocator);
            errdefer list.clearAndFree();
            while (true) {
                const tres = try self.til.parseLeaky(allocator, src);
                if (tres) |_| {
                    return list.items;
                }
                const many_res = try self.many_of.parseLeaky(allocator, src) orelse {
                    if (list.items.len > 0) {
                        return error.PartiallyConsumed;
                    } else {
                        list.clearAndFree();
                        return null;
                    }
                };

                try list.append(many_res);
            }
        }

        pub fn parser(self: *Self) Parser([]ManyVal, Reader) {
            return .{ .ptr = self, .table = .{ ._parse = parse } };
        }
    };
}

/// Errors if can't get position in stream.
/// For parsers that would fail with a "error.PartiallyConsumed", this rolls back
/// the reader to the start of the parse.
pub fn Backtrack(comptime Value: type, comptime Reader: type) type {
    return struct {
        child_parser: Parser(Value, Reader),

        const Self = @This();

        pub fn init(child: Parser(Value, Reader)) Self {
            return .{ .child_parser = child };
        }
        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?Value {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const start_pos = try src.seekableStream().getPos();
            const res = self.child_parser.parseLeaky(allocator, src) catch |err| {
                switch (err) {
                    error.PartiallyConsumed => {
                        try src.seekableStream().seekTo(start_pos);
                        return null;
                    },
                    _ => return err,
                }
            };
            return res;
        }
        pub fn parser(self: *Self) Parser(Value, Reader) {
            return .{ .ptr = self, .table = .{ ._parse = &parse } };
        }
    };
}

/// Returns 0 or more values parsed in a row
/// Always succeeds, unless the child parser were to return a partial consumtion/other error
pub fn Many(comptime Value: type, comptime Reader: type) type {
    return struct {
        many_of: Parser(Value, Reader),

        const Self = @This();
        pub fn init(many_of: Parser(Value, Reader)) Self {
            return Self{ .many_of = many_of };
        }

        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?[]Value {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const list = std.ArrayList(Value).init(allocator);
            errdefer list.clearAndFree();
            while (true) {
                const res = try self.many_of.parseLeaky(allocator, src);
                if (res) |r| {
                    list.append(r);
                } else {
                    return list.items;
                }
            }
        }
        pub fn parser(self: *Self) Parser([]Value, Reader) {
            return .{ .ptr = self, .table = .{ ._parse = &parse } };
        }
    };
}

/// Returns 1 or more values parsed in a row
pub fn Some(comptime Value: type, comptime Reader: type) type {
    return struct {
        some_of: Parser(Value, Reader),

        const Self = @This();
        pub fn init(some_of: Parser(Value, Reader)) Self {
            return Self{ .some_of = some_of };
        }
        fn parse(ctx: *anyopaque, allocator: Allocator, src: *Reader) anyerror!?[]Value {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const list = std.ArrayList(Value).init(allocator);
            errdefer list.clearAndFree();
            const first = try self.some_of.parseLeaky(allocator, src) orelse return null;
            list.append(first);
            while (true) {
                const res = try self.some_of.parseLeaky(allocator, src);
                if (res) |r| {
                    list.append(r);
                } else {
                    return list.items;
                }
            }
        }
    };
}

test "simple literal" {
    const in_file = "egg!";
    var fbs = std.io.fixedBufferStream(in_file);
    const testing_allocator = testing.allocator;
    var literal = Literal(@TypeOf(fbs)).init("egg");
    const res = try literal.parser().parse(testing_allocator, &fbs) orelse return error.FailedParse;
    defer res.deinit();
    try testing.expectEqualStrings("egg", res.value);
}

test "many till" {
    const in_file = "OOWOO WHATS HTIS :3 aaaaa";
    var fbs = std.io.fixedBufferStream(in_file);
    var literal = Literal(@TypeOf(fbs)).init(":3");
    var voided = Voided([]u8, @TypeOf(fbs)).init(literal.parser());
    var many_till = ManyTill(u8, void, @TypeOf(fbs)).init(AnyChar(@TypeOf(fbs)).parser(), voided.parser());
    const res = try many_till.parser().parse(testing.allocator, &fbs) orelse return error.FailedParse;
    defer res.deinit();
    try testing.expectEqualStrings("OOWOO WHATS HTIS ", res.value);
}
