const std = @import("std");
const linux = std.os.linux;

const MAX_EVENTS = 30;
const basepath = "/dev/input/";

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("libudev.h");
    @cInclude("libevdev-1.0/libevdev/libevdev.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

events_registry: Registry,
epoll_fd: usize,
xkb_context: ?*c.xkb_context,
keymap: ?*c.xkb_keymap,
xkb_state: ?*c.xkb_state,
udev: ?*c.struct_udev,
monitor: ?*c.udev_monitor,
udev_fd: c_int,
udev_event: *linux.epoll_event,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    var result: @This() = undefined;

    result.epoll_fd = linux.epoll_create();
    result.events_registry = .init(result.epoll_fd);
    errdefer result.events_registry.deinit(gpa);

    result.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    if (result.xkb_context == null) return error.XkbContextInitFailed;
    errdefer c.xkb_context_unref(result.xkb_context);

    const rule_names: c.xkb_rule_names = .{
        .model = "pc105",
        .layout = "us",
    };
    result.keymap = c.xkb_keymap_new_from_names2(result.xkb_context, &rule_names, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (result.keymap == null) return error.XkbKeymapInitFailed;
    errdefer c.xkb_keymap_unref(result.keymap);

    result.xkb_state = c.xkb_state_new(result.keymap);
    if (result.xkb_state == null) return error.XkbStateInitFailed;
    errdefer c.xkb_state_unref(result.xkb_state);

    // Evdev
    {
        const input_folder: std.Io.Dir = try std.Io.Dir.cwd().openDir(io, basepath, .{
            .iterate = true,
        });
        defer input_folder.close(io);
        var iterator = input_folder.iterate();

        while (try iterator.next(io)) |file| {
            const path = try gpa.alloc(u8, basepath.len + file.name.len + 1);
            defer gpa.free(path);

            @memcpy(path[0..basepath.len], basepath);
            @memcpy(path[basepath.len..basepath.len + file.name.len], file.name);
            path[path.len - 1] = 0;

            result.events_registry.registerDevice(gpa, @ptrCast(path)) catch |err| switch (err) {
                error.evdevFdFailure => continue,
                else => return err,
            };
        }
    }

    // Udev
    result.udev = c.udev_new();
    errdefer _ = c.udev_unref(result.udev);
    result.monitor = c.udev_monitor_new_from_netlink(result.udev, "udev");
    errdefer _ = c.udev_monitor_unref(result.monitor);
    // Filtre
    _ = c.udev_monitor_filter_add_match_subsystem_devtype(result.monitor, "input", null);
    _ = c.udev_monitor_enable_receiving(result.monitor);
    result.udev_fd = c.udev_monitor_get_fd(result.monitor);

    const udev_context = try gpa.create(Context);
    errdefer gpa.destroy(udev_context);
    udev_context.* = .udev;
    result.udev_event = try gpa.create(linux.epoll_event);
    errdefer gpa.destroy(result.udev_event);
    result.udev_event.* = .{
        .events = linux.EPOLL.IN,
        .data = .{ .ptr = @intFromPtr(udev_context) },
    };

    _ = std.os.linux.epoll_ctl(@intCast(result.epoll_fd), std.os.linux.EPOLL.CTL_ADD, result.udev_fd, result.udev_event);

    std.log.info("All events registered\n", .{});

    return result;
}

// Defers are used to keep the code order from init, since things must be deinited in opposite order
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    defer self.events_registry.deinit(gpa);

    defer c.xkb_context_unref(self.xkb_context);
    defer c.xkb_keymap_unref(self.keymap);
    defer c.xkb_state_unref(self.xkb_state);

    defer _ = c.udev_unref(self.udev);
    defer _ = c.udev_monitor_unref(self.monitor);
    defer gpa.destroy(self.udev_event);
    defer gpa.destroy(@as(*Context, @ptrFromInt(self.udev_event.data.ptr)));
}

pub const KeyType = c.xkb_keysym_t;

pub fn poll(self: *@This(), gpa: std.mem.Allocator, accumulator: *std.ArrayList(KeyType)) !void {
    var events: [MAX_EVENTS]linux.epoll_event = undefined;

    const count = linux.epoll_wait(@intCast(self.epoll_fd), &events, MAX_EVENTS, -1);

    for (events[0..count]) |event| {
        const context: *Context = @ptrFromInt(event.data.ptr);

        switch (context.*) {
            .udev => {
                const device = c.udev_monitor_receive_device(self.monitor);
                defer _ = c.udev_device_unref(device);
                if (device != null) {
                    const action = c.udev_device_get_action(device);
                    const node = c.udev_device_get_devnode(device);

                    if (action != null and node != null) {
                        const action_name = std.mem.span(action);
                        const action_type = std.meta.stringToEnum(Actions, action_name);

                        switch (action_type orelse continue) {
                            .add => {
                                std.log.info("Registering new device: {s}", .{ node });
                                self.events_registry.registerDevice(gpa, node) catch |err| switch (err) {
                                    error.evdevFdFailure => std.log.warn("Device failed to register: evdev error", .{}),
                                    else => return err,
                                };
                            },
                            .remove => {
                                std.log.info("Cleaning up device: {s}\n", .{ node });
                                const name = std.mem.span(node);
                                const data = self.events_registry.events_map.fetchRemove(name) orelse {
                                    std.log.warn("Device data not found (Device: {s})\n", .{ node });
                                    continue;
                                };
                                gpa.free(data.key);
                                _ = linux.close(data.value.fd);

                                const old_context: *Context = @ptrFromInt(data.value.event.data.ptr);
                                c.libevdev_free(old_context.evdev);
                                gpa.destroy(old_context);
                            },
                        }
                    }
                }
            },
            .evdev => |ev_device| {
                var ev_event: c.input_event = undefined;
                var flag: c_uint = c.LIBEVDEV_READ_FLAG_NORMAL;

                while (true) {
                    switch (c.libevdev_next_event(ev_device, flag, &ev_event)) {
                        c.LIBEVDEV_READ_STATUS_SUCCESS => {
                            if (ev_event.type != c.EV_KEY) continue;
                            const keycode = ev_event.code + 8;

                            const KeyValues = struct {
                                const KEY_UP = 0;
                                const KEY_DOWN = 1;
                                const KEY_REPEAT = 2;
                            };

                            switch (ev_event.value) {
                                KeyValues.KEY_UP => _ = c.xkb_state_update_key(self.xkb_state, keycode, c.XKB_KEY_UP),
                                KeyValues.KEY_DOWN => {
                                    _ = c.xkb_state_update_key(self.xkb_state, keycode, c.XKB_KEY_DOWN);
                                    continue;
                                },
                                KeyValues.KEY_REPEAT => {
                                    if (c.xkb_key_repeats(self.keymap, keycode) == 0) continue;
                                },
                                else => {
                                    std.debug.print("Unhandled EV event value: {d}\n", .{ ev_event.value });
                                    return error.UnhandledEVValue;
                                },
                            }

                            const keysym = c.xkb_state_key_get_one_sym(self.xkb_state, keycode);

                            try accumulator.append(gpa, keysym);
                        },
                        c.LIBEVDEV_READ_STATUS_SYNC => flag = c.LIBEVDEV_READ_FLAG_SYNC,
                        -c.EAGAIN => {
                            if (flag == c.LIBEVDEV_READ_FLAG_SYNC) {
                                flag = c.LIBEVDEV_READ_FLAG_NORMAL;
                            }
                            break;
                        },
                        -19, -7 => break,
                        else => |err| {
                            std.log.err("Libevdev next event error: {d}", .{ err });
                            break;
                        },
                    }
                }
            }
        }
    }
}

const Context = union(enum) {
    udev,
    evdev: ?*c.struct_libevdev,
};

const Actions = enum {
    add,
    remove,
};

const EventInfo = struct {
    fd: i32,
    event: linux.epoll_event,
};

/// A structure made to help free event fd and contexts
const Registry = struct {
    epoll_fd: usize,
    // A hashmap on event's fd
    events_map: std.hash_map.StringHashMapUnmanaged(EventInfo),

    fn init(epoll_fd: usize) Registry {
        return .{
            .epoll_fd = epoll_fd,
            .events_map = .empty,
        };
    }

    fn registerDevice(self: *Registry, gpa: std.mem.Allocator, path: [*:0]const u8) !void {
        // We don't care about perm since we never create the file
        const fd = linux.open(path, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
        }, 0);
        errdefer _ = linux.close(@intCast(fd));

        const ev_context = try gpa.create(Context);
        errdefer gpa.destroy(ev_context);
        ev_context.* = .{ .evdev = null };
        const return_code = c.libevdev_new_from_fd(@intCast(fd), &ev_context.evdev);
        if (return_code < 0) return error.evdevFdFailure;
        errdefer c.libevdev_free(ev_context.evdev);

        const info = try self.events_map.getOrPut(gpa, try gpa.dupe(u8, std.mem.span(path)));
        info.value_ptr.fd = @intCast(fd);
        info.value_ptr.event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(ev_context) },
        };

        _ = linux.epoll_ctl(@intCast(self.epoll_fd), linux.EPOLL.CTL_ADD, @intCast(fd), &info.value_ptr.event);
    }

    fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        defer self.events_map.deinit(gpa);
        var iterator = self.events_map.iterator();
        while (iterator.next()) |entry| {
            defer gpa.free(entry.key_ptr.*);
            const context: *Context = @ptrFromInt(entry.value_ptr.event.data.ptr);
            defer gpa.destroy(context);
            switch (context.*) {
                .udev => {},
                .evdev => |evdev| {
                    c.libevdev_free(evdev);
                },
            }
            _ = linux.close(@intCast(entry.value_ptr.fd));
        }
    }
};

pub fn getKeyText(key: KeyType) !struct { [5]u8, usize } {
    var buffer: [5]u8 = undefined;
    const size = c.xkb_keysym_to_utf8(key, &buffer, buffer.len);
    return switch (size) {
        -1 => error.BufferTooSmall,
        0 => error.NoUTF8Representation,
        else => .{ buffer, @intCast(size) },
    };
}

pub fn main(base: std.process.Init) !void {
    var input_manager: @This() = try .init(base.gpa, base.io);
    defer input_manager.deinit(base.gpa);

    var accumulator: std.ArrayList(KeyType) = .empty;
    defer accumulator.deinit(base.gpa);

    std.debug.print("Press Q to quit\n", .{});
    while (true) {
        try input_manager.poll(base.gpa, &accumulator);

        for (accumulator.items) |keysym| {
            if (keysym == KEYS.q or keysym == KEYS.Q) return;
            const text = getKeyText(keysym) catch continue;
            std.debug.print("Pressed text: {s}\n", .{ text.@"0"[0..text.@"1"] });
        }

        accumulator.clearRetainingCapacity();
    }
}


const KEYS_TYPE = blk: {
    const decls = @typeInfo(c).@"struct".decls;

    var names: [decls.len][]const u8 = undefined;
    const types: [decls.len]type = @splat(c_int);
    var attributes: [decls.len]std.builtin.Type.StructField.Attributes = undefined;
    var count = 0;

    // 10k wasn't enough
    @setEvalBranchQuota(100000);
    for (decls) |declaration| {
        if (std.mem.startsWith(u8, declaration.name, "XKB_KEY_")) {
            names[count] = declaration.name["XKB_KEY_".len..];
            attributes[count] = .{
                .@"comptime" = true,
                .default_value_ptr = @alignCast(@ptrCast(&@field(c, declaration.name))),
            };
            count += 1;
        }
    }

    break :blk @Struct(.auto, null, names[0..count], types[0..count], attributes[0..count]);
};

pub const KEYS: KEYS_TYPE = .{};
