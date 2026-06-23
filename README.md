# _deque.zig_

a lock free chase-lev deque for zig.

## usage

```zig
const std = @import("std");
const Thread = std.Thread;

const deque = @import("deque");

const AMOUNT: usize = 100_000;

const Task = struct {
    const Self = @This();
    stealer: deque.Stealer(usize),
    data: [AMOUNT]usize = [_]usize{0} ** AMOUNT,

    fn task(self: *Self) !void {
        while (self.stealer.steal()) |val| {
            self.data[val] += 1;
        }
    }

    fn verify(self: Self) !void {
        for (self.data) |val| {
            try std.testing.expectEqual(val, 1);
        }
    }
};

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(buffer);

    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.threadSafeAllocator();

    var d = try deque.Deque(usize).init(allocator);
    defer d.deinit();

    const worker = d.worker();
    for (0..AMOUNT) |idx| try worker.push(idx);

    var task = Task{
        .stealer = d.stealer(),
    };

    var threads: [4]Thread = undefined;
    for (&threads) |*thread| thread.* = try Thread.spawn(.{}, Task.task, .{&task});

    for (threads) |thread| thread.join();

    try task.verify();
}
```
