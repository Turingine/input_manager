const std = @import("std");
const InputManager = @import("input_manager");
const KEYS = InputManager.KEYS;

pub fn main(base: std.process.Init) !void {
    var input_manager: InputManager = try .init(base.gpa, base.io);
    defer input_manager.deinit(base.gpa);

    var accumulator: std.ArrayList(InputManager.KeyType) = .empty;
    defer accumulator.deinit(base.gpa);

    std.debug.print("Press Q to quit\n", .{});
    while (true) {
        try input_manager.poll(base.gpa, &accumulator);

        for (accumulator.items) |keysym| {
            if (keysym == KEYS.q or keysym == KEYS.Q) return;

            var buffer: [50]u8 = undefined;
            const size = InputManager.c.xkb_keysym_get_name(keysym, &buffer, buffer.len);

            std.debug.print("Keysym name: {s}\n", .{ buffer[0..@intCast(size)] });
        }

        accumulator.clearRetainingCapacity();
    }
}

