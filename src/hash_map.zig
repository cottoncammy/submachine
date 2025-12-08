const std = @import("std");

pub fn Context(comptime K: type) type {
    return struct {
        pub fn hash(ctx: @This(), key: K) u64 {
            _ = ctx;
            var hasher: std.hash.Wyhash = .init(0);
            hashStruct(&hasher, key);
            return hasher.final();
        }

        pub fn eql(ctx: @This(), a: K, b: K) bool {
            _ = ctx;
            return std.meta.eql(a, b);
        }

        fn hashStruct(hasher: *std.hash.Wyhash, value: anytype) void {
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                const field_value = @field(value, field.name);
                switch (@typeInfo(field.type)) {
                    .float => |float| {
                        if (float.bits == 32) {
                            std.hash.autoHash(hasher, @as(u32, @bitCast(field_value)));
                        } else {
                            std.hash.autoHash(hasher, @as(u64, @bitCast(field_value)));
                        }
                    },
                    .@"struct" => hashStruct(hasher, field_value),
                    else => std.hash.autoHash(hasher, field_value),
                }
            }
        }
    };
}
