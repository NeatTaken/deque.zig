//  Copyright (c) 2020 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

fn CircularBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,

        fn init(allocator: Allocator, cap: usize) !Self {
            std.debug.assert(std.math.isPowerOfTwo(cap));
            return .{ .buf = try allocator.alloc(T, cap) };
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.buf);
        }

        inline fn mask(self: *const Self, i: isize) usize {
            return @intCast(i & @as(isize, @intCast(self.buf.len - 1)));
        }

        fn at(self: *const Self, i: isize) *T {
            return &self.buf[self.mask(i)];
        }

        fn put(self: *Self, i: isize, val: T) void {
            self.buf[self.mask(i)] = val;
        }

        fn grow(self: *const Self, allocator: Allocator, top: isize, bottom: isize) !Self {
            var next = try Self.init(allocator, self.buf.len * 2);
            var i: isize = top;
            while (i < bottom) : (i += 1) {
                next.put(i, self.at(i).*);
            }
            return next;
        }
    };
}

pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        const Buffer = CircularBuffer(T);
        const INITIAL_CAP = 32;

        allocator: Allocator,
        buffer: Atomic(*Buffer),
        bottom: Atomic(isize),
        top: Atomic(isize),

        pub fn init(allocator: Allocator, ) !Self {
            const buf = try allocator.create(Buffer);
            buf.* = try Buffer.init(allocator, INITIAL_CAP);
            return .{
                .allocator = allocator,
                .buffer = Atomic(*Buffer).init(buf),
                .bottom = Atomic(isize).init(0),
                .top = Atomic(isize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            const buf = self.buffer.load(.monotonic);
            buf.deinit(self.allocator);
            self.allocator.destroy(buf);
        }

        pub fn worker(self: *Self) Worker(T) {
            return .{ .deque = self };
        }

        pub fn stealer(self: *Self) Stealer(T) {
            return .{ .deque = self };
        }

        fn push(self: *Self, item: T) !void {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            var buf = self.buffer.load(.monotonic);

            if (b -% t >= @as(isize, @intCast(buf.buf.len - 1))) {
                const old = buf;
                const new_buf = try self.allocator.create(Buffer);
                new_buf.* = try old.grow(self.allocator, t, b);
                self.buffer.store(new_buf, .release);
                buf = new_buf;
                //old.deinit(self.allocator);   // <-- NOT SAFE WITH CONCURRENT STEALERS
                //self.allocator.destroy(old);  //     TANK THE LEAK FOR NOW
            }

            buf.put(b, item);
            self.bottom.store(b +% 1, .release);
        }

        fn pop(self: *Self) ?T {
            var b = self.bottom.load(.monotonic);
            const buf = self.buffer.load(.monotonic);

            b -%= 1;
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);

            const size = b -% t;
            if (size < 0) {
                self.bottom.store(b +% 1, .monotonic);
                return null;
            }

            const val = buf.at(b).*;
            if (size == 0) {
                if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                    self.bottom.store(b +% 1, .monotonic);
                    return null;
                }
                self.bottom.store(b +% 1, .monotonic);
            }

            return val;
        }

        fn steal(self: *Self) ?T {
            while (true) {
                const t = self.top.load(.seq_cst);
                const b = self.bottom.load(.seq_cst);
                if (b -% t <= 0) return null;

                const buf = self.buffer.load(.acquire);
                const val = buf.at(t).*;

                if (self.top.cmpxchgWeak(t, t +% 1, .seq_cst, .monotonic) != null) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                return val;
            }
        }
    };
}

pub fn Worker(comptime T: type) type {
    return struct {
        const Self = @This();
        deque: *Deque(T),

        pub fn push(self: *const Self, item: T) !void {
            try self.deque.push(item);
        }

        pub fn pop(self: *const Self) ?T {
            return self.deque.pop();
        }
    };
}

pub fn Stealer(comptime T: type) type {
    return struct {
        const Self = @This();
        deque: *Deque(T),

        pub fn steal(self: *const Self) ?T {
            return self.deque.steal();
        }
    };
}
