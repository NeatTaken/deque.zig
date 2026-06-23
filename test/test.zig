const std = @import("std");
const Thread = std.Thread;

const deque = @import("deque");

const AMOUNT: usize = 10_000;

test "single-thread" {
    const S = struct {
        fn task(stealer: deque.Stealer(usize)) !void {
            var left: usize = AMOUNT;
            while (stealer.steal()) |val| {
                try std.testing.expectEqual(val + left, AMOUNT);
                try std.testing.expectEqual(AMOUNT - val, left);
                left -= 1;
            }
            try std.testing.expectEqual(@as(usize, 0), left);
        }
    };

    const buffer = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);

    var test_deque = try deque.Deque(usize).init(fba.threadSafeAllocator());
    defer test_deque.deinit();

    const worker = test_deque.worker();
    for (0..AMOUNT) |idx| try worker.push(idx);

    const thread = try Thread.spawn(.{}, S.task, .{test_deque.stealer()});
    thread.join();
}

test "multiple-threads" {
    const S = struct {
        const Self = @This();
        stealer: deque.Stealer(usize),
        data: [AMOUNT]usize = [_]usize{0} ** AMOUNT,

        fn task(self: *Self) !void {
            while (self.stealer.steal()) |val| self.data[val] += 1;
        }

        fn verify(self: *const Self) !void {
            for (self.data) |val| try std.testing.expectEqual(val, 1);
        }
    };

    const buffer = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);

    var test_deque = try deque.Deque(usize).init(fba.threadSafeAllocator());
    defer test_deque.deinit();

    const worker = test_deque.worker();
    for (0..AMOUNT) |idx| try worker.push(idx);

    var ctx = S{ .stealer = test_deque.stealer() };
    var threads: [4]Thread = undefined;
    for (&threads) |*t| t.* = try Thread.spawn(.{}, S.task, .{&ctx});
    for (threads) |t| t.join();
    try ctx.verify();
}
