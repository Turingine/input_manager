const std = @import("std");
const linux = std.os.linux;

const MAX_EVENTS = 30;
const basepath = "/dev/input/";

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("libudev.h");
    @cInclude("libevdev-1.0/libevdev/libevdev.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-compose.h");
});

events_registry: Registry,
epoll_fd: usize,
xkb_context: ?*c.xkb_context,
keymap: ?*c.xkb_keymap,
xkb_state: ?*c.xkb_state,
compose_table: ?*c.xkb_compose_table,
compose_state: ?*c.xkb_compose_state,
udev: ?*c.struct_udev,
monitor: ?*c.udev_monitor,
udev_fd: c_int,
udev_event: *linux.epoll_event,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    var result: @This() = undefined;

    result.epoll_fd = linux.epoll_create();
    result.events_registry = .init(result.epoll_fd);
    errdefer result.events_registry.deinit(gpa);

    // The calculator keyboard (keyboardd) emits AZERTY positions: decoding them
    // with "us" gave `sin5)-` for `sin(0)`
    // (docs/apps/calculator-problemes-zig.md, section 6).
    var layout = try SystemLayout.read(gpa, io);
    defer layout.deinit(gpa);
    try result.initXkb(&layout.ruleNames(), composeLocale());
    errdefer result.deinitXkb();

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
                error.OpenError => {
                    std.log.err("Failed to open event file: {s}", .{ path });
                    continue;
                },
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

    defer self.deinitXkb();

    defer _ = c.udev_unref(self.udev);
    defer _ = c.udev_monitor_unref(self.monitor);
    defer gpa.destroy(self.udev_event);
    defer gpa.destroy(@as(*Context, @ptrFromInt(self.udev_event.data.ptr)));
}

/// XKB part of init: context, keymap, state and compose table. Separate from
/// init so that the tests can build it without /dev/input.
fn initXkb(self: *@This(), rule_names: *const c.xkb_rule_names, locale: [*:0]const u8) !void {
    self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    if (self.xkb_context == null) return error.XkbContextInitFailed;
    errdefer c.xkb_context_unref(self.xkb_context);

    self.keymap = c.xkb_keymap_new_from_names2(self.xkb_context, rule_names, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (self.keymap == null) return error.XkbKeymapInitFailed;
    errdefer c.xkb_keymap_unref(self.keymap);
    std.log.info("Layout: {s}", .{ c.xkb_keymap_layout_get_name(self.keymap, 0) });

    self.xkb_state = c.xkb_state_new(self.keymap);
    if (self.xkb_state == null) return error.XkbStateInitFailed;
    errdefer c.xkb_state_unref(self.xkb_state);

    // Dead keys: keyboardd types x² as on a real AZERTY keyboard, dead ^ then
    // Space, and a dead key alone has no text. Without a compose table they
    // produce nothing, which is a degraded mode, not a reason to fail.
    self.compose_state = null;
    self.compose_table = c.xkb_compose_table_new_from_locale(self.xkb_context, locale, c.XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (self.compose_table == null) {
        std.log.warn("No compose table for locale {s}: dead keys will produce nothing", .{locale});
        return;
    }
    self.compose_state = c.xkb_compose_state_new(self.compose_table, c.XKB_COMPOSE_STATE_NO_FLAGS);
    if (self.compose_state == null) {
        std.log.warn("Compose state creation failed: dead keys will produce nothing", .{});
        c.xkb_compose_table_unref(self.compose_table);
        self.compose_table = null;
    }
}

// The *_unref functions accept null, hence no check for the compose part.
fn deinitXkb(self: *@This()) void {
    defer c.xkb_context_unref(self.xkb_context);
    defer c.xkb_keymap_unref(self.keymap);
    defer c.xkb_state_unref(self.xkb_state);
    defer c.xkb_compose_table_unref(self.compose_table);
    defer c.xkb_compose_state_unref(self.compose_state);
}

/// Locale of the compose table, looked up as setlocale(LC_CTYPE, "") would.
/// libxkbcommon falls back to en_US.UTF-8 for C and POSIX.
fn composeLocale() [*:0]const u8 {
    for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (std.c.getenv(name)) |value| {
            if (value[0] != 0) return value;
        }
    }
    return "C";
}

/// Keyboard layout of the system, read from /etc/default/keyboard as
/// keyboardd and core/input/evdev_input do. A field left empty falls back to
/// XKB_DEFAULT_* or to the libxkbcommon default (pc105, us).
const SystemLayout = struct {
    model: [:0]const u8 = "",
    layout: [:0]const u8 = "",
    variant: [:0]const u8 = "",
    options: [:0]const u8 = "",

    const path = "/etc/default/keyboard";

    fn read(gpa: std.mem.Allocator, io: std.Io) !SystemLayout {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| {
            std.log.warn("{s} unreadable ({s}): default XKB layout", .{ path, @errorName(err) });
            var result: SystemLayout = .{};
            try result.addNumpadMac(gpa);
            return result;
        };
        defer gpa.free(text);
        return parse(gpa, text);
    }

    /// Shell syntax, KEY="value" per line. The fields are copies: the result
    /// does not borrow from text.
    fn parse(gpa: std.mem.Allocator, text: []const u8) !SystemLayout {
        var result: SystemLayout = .{};
        errdefer result.deinit(gpa);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..equal];
            const field = if (std.mem.eql(u8, key, "XKBMODEL"))
                &result.model
            else if (std.mem.eql(u8, key, "XKBLAYOUT"))
                &result.layout
            else if (std.mem.eql(u8, key, "XKBVARIANT"))
                &result.variant
            else if (std.mem.eql(u8, key, "XKBOPTIONS"))
                &result.options
            else
                continue;
            const value = std.mem.trim(u8, line[equal + 1 ..], "\"'");
            // An empty value keeps the "" literal: only non-empty fields are
            // allocated, which is what deinit relies on.
            const copy: [:0]const u8 = if (value.len == 0) "" else try gpa.dupeZ(u8, value);
            if (field.len != 0) gpa.free(field.*);
            field.* = copy;
        }
        try result.addNumpadMac(gpa);
        return result;
    }

    /// Keypad digits whatever Num Lock says. keyboardd sends the calculator
    /// digits as KEY_KP*, which XKB turns into KP_End & co. without Num Lock,
    /// and Num Lock state is per application: this option is the fix that
    /// docs/services/keyboard.md recommends. A numpad option already set by
    /// the system is kept.
    fn addNumpadMac(self: *SystemLayout, gpa: std.mem.Allocator) !void {
        if (std.mem.indexOf(u8, self.options, "numpad:") != null) return;
        const options = if (self.options.len == 0)
            try gpa.dupeZ(u8, "numpad:mac")
        else
            try std.mem.concatWithSentinel(gpa, u8, &.{ self.options, ",numpad:mac" }, 0);
        if (self.options.len != 0) gpa.free(self.options);
        self.options = options;
    }

    /// Borrows from self, which must outlive the keymap compilation.
    fn ruleNames(self: *const SystemLayout) c.xkb_rule_names {
        return .{
            .model = self.model.ptr,
            .layout = self.layout.ptr,
            .variant = self.variant.ptr,
            .options = self.options.ptr,
        };
    }

    fn deinit(self: *SystemLayout, gpa: std.mem.Allocator) void {
        for ([_][:0]const u8{ self.model, self.layout, self.variant, self.options }) |field| {
            if (field.len != 0) gpa.free(field);
        }
        self.* = .{};
    }
};

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
                            if (try self.handleKey(ev_event.code, ev_event.value)) |keysym| {
                                try accumulator.append(gpa, keysym);
                            }
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

/// Feeds one evdev key event to XKB and returns the keysym it types, if any.
/// A key types when pressed and when repeated, as on any keyboard; it used to
/// type when released, which delayed every character and made Shift released
/// a little early change the result. The keysym is read before the state
/// update, as in the xkbcommon quick guide.
fn handleKey(self: *@This(), code: u16, value: i32) !?KeyType {
    const keycode = @as(c.xkb_keycode_t, code) + 8; // evdev to XKB numbering

    const KeyValues = struct {
        const KEY_UP = 0;
        const KEY_DOWN = 1;
        const KEY_REPEAT = 2;
    };

    const keysym = switch (value) {
        KeyValues.KEY_UP => {
            _ = c.xkb_state_update_key(self.xkb_state, keycode, c.XKB_KEY_UP);
            return null;
        },
        KeyValues.KEY_DOWN => blk: {
            const keysym = c.xkb_state_key_get_one_sym(self.xkb_state, keycode);
            _ = c.xkb_state_update_key(self.xkb_state, keycode, c.XKB_KEY_DOWN);
            break :blk keysym;
        },
        KeyValues.KEY_REPEAT => blk: {
            if (c.xkb_key_repeats(self.keymap, keycode) == 0) return null;
            break :blk c.xkb_state_key_get_one_sym(self.xkb_state, keycode);
        },
        else => {
            std.debug.print("Unhandled EV event value: {d}\n", .{value});
            return error.UnhandledEVValue;
        },
    };
    // Mouse buttons are EV_KEY too, and map to no keysym.
    if (keysym == c.XKB_KEY_NoSymbol) return null;
    return self.compose(keysym);
}

/// Runs a keysym through the compose table: the same keysym outside of a
/// sequence, the composed one at its end (dead ^ then e gives ê), and null
/// while a sequence is pending or once it is cancelled, the keysym that
/// cancels it included, as libxkbcommon recommends.
fn compose(self: *@This(), keysym: KeyType) ?KeyType {
    const state = self.compose_state orelse return keysym;
    // Modifiers are ignored by the table, and must not break a sequence.
    if (c.xkb_compose_state_feed(state, keysym) == c.XKB_COMPOSE_FEED_IGNORED) return keysym;
    switch (c.xkb_compose_state_get_status(state)) {
        c.XKB_COMPOSE_COMPOSING => return null,
        c.XKB_COMPOSE_COMPOSED => {
            const composed = c.xkb_compose_state_get_one_sym(state);
            c.xkb_compose_state_reset(state);
            // A sequence can produce a string with no single keysym.
            return if (composed == c.XKB_KEY_NoSymbol) null else composed;
        },
        c.XKB_COMPOSE_CANCELLED => {
            c.xkb_compose_state_reset(state);
            return null;
        },
        else => return keysym,
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
        if (@as(isize, @bitCast(fd)) < 0) return error.OpenError;
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

const UTF8Char = struct {
    data: [5]u8,
    // The real amount of bytes of data occupied by the unicode codepoint, not accounting for the null terminator
    bytes_occupied: usize,

    // Be careful with lifetime, the returned string only lives as long as the provided struct
    pub fn slice(self: UTF8Char) []const u8 {
        return self.data[0..self.bytes_occupied];
    }
};

/// Text of a keysym. The length leaves out the terminating NUL, which
/// xkb_keysym_to_utf8 counts: it used to end up in the text. Control
/// characters (Return, BackSpace, Tab, Escape, Delete) are not text either: an
/// app handles them by keysym, and inserting them put an invisible DEL in the
/// input (docs/apps/calculator-problemes-zig.md, test J9).
pub fn getKeyText(key: KeyType) !UTF8Char {
    var buffer: [5]u8 = undefined;
    const size = c.xkb_keysym_to_utf8(key, &buffer, buffer.len);

    switch (size) {
        -1 => return error.BufferTooSmall,
        0 => return error.NoUTF8Representation,
        else => {
            const len: usize = @intCast(size - 1);
            if (len == 1 and (buffer[0] < 0x20 or buffer[0] == 0x7f)) return error.ControlCharacter;
            return .{ 
                .data = buffer,
                .bytes_occupied = len,
            };
        }
    }
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

test "SystemLayout: /etc/default/keyboard of the calculator" {
    const gpa = std.testing.allocator;
    var layout = try SystemLayout.parse(gpa,
        \\# KEYBOARD CONFIGURATION FILE
        \\
        \\XKBMODEL="pc105"
        \\XKBLAYOUT="fr"
        \\XKBVARIANT=""
        \\XKBOPTIONS=""
        \\
        \\BACKSPACE="guess"
        \\
    );
    defer layout.deinit(gpa);
    try std.testing.expectEqualStrings("pc105", layout.model);
    try std.testing.expectEqualStrings("fr", layout.layout);
    try std.testing.expectEqualStrings("", layout.variant);
    try std.testing.expectEqualStrings("numpad:mac", layout.options);
}

test "SystemLayout: options of the system are kept" {
    const gpa = std.testing.allocator;
    {
        var layout = try SystemLayout.parse(gpa, "XKBLAYOUT=fr\nXKBOPTIONS=\"grp:alt_shift_toggle\"\n");
        defer layout.deinit(gpa);
        try std.testing.expectEqualStrings("grp:alt_shift_toggle,numpad:mac", layout.options);
    }
    {
        // An explicit numpad option wins, and the last line of a key too.
        var layout = try SystemLayout.parse(gpa, "XKBOPTIONS=\"numpad:microsoft\"\nXKBLAYOUT=\"us\"\nXKBLAYOUT=\"fr\"");
        defer layout.deinit(gpa);
        try std.testing.expectEqualStrings("numpad:microsoft", layout.options);
        try std.testing.expectEqualStrings("fr", layout.layout);
    }
}

test "Calculator keyboard: AZERTY, keypad, AltGr, dead keys" {
    var im = try testKeyboard();
    defer im.deinitXkb();

    // AZERTY positions, as keyboardd types sin(0).
    try expectText("s", try im.tap(c.KEY_S));
    try expectText("a", try im.tap(c.KEY_Q));
    try expectText("(", try im.tap(c.KEY_5));
    try expectText("é", try im.tap(c.KEY_2));
    _ = try im.handleKey(c.KEY_LEFTSHIFT, 1);
    try expectText("2", try im.tap(c.KEY_2));
    _ = try im.handleKey(c.KEY_LEFTSHIFT, 0);
    try expectText("é", try im.tap(c.KEY_2));

    // Keypad digits without Num Lock, and EXE.
    try expectText("1", try im.tap(c.KEY_KP1));
    try expectText("+", try im.tap(c.KEY_KPPLUS));
    try std.testing.expectEqual(@as(?KeyType, c.XKB_KEY_KP_Enter), try im.tap(c.KEY_KPENTER));

    // AltGr, the right Alt.
    _ = try im.handleKey(c.KEY_RIGHTALT, 1);
    try expectText("@", try im.tap(c.KEY_0));
    try expectText("€", try im.tap(c.KEY_E));
    _ = try im.handleKey(c.KEY_RIGHTALT, 0);
    try expectText("à", try im.tap(c.KEY_0));

    // Dead keys: keyboardd types x² as dead ^ then Space.
    try std.testing.expectEqual(@as(?KeyType, null), try im.tap(c.KEY_LEFTBRACE));
    try expectText("^", try im.tap(c.KEY_SPACE));
    try std.testing.expectEqual(@as(?KeyType, null), try im.tap(c.KEY_LEFTBRACE));
    try expectText("ê", try im.tap(c.KEY_E));
}

test "A key types when pressed and repeated, not when released" {
    var im = try testKeyboard();
    defer im.deinitXkb();

    try expectText("z", try im.handleKey(c.KEY_W, 1));
    try expectText("z", try im.handleKey(c.KEY_W, 2));
    try std.testing.expectEqual(@as(?KeyType, null), try im.handleKey(c.KEY_W, 0));
    // A mouse button is an EV_KEY with no keysym.
    try std.testing.expectEqual(@as(?KeyType, null), try im.handleKey(c.BTN_LEFT, 1));
    _ = try im.handleKey(c.BTN_LEFT, 0);
}

test "getKeyText: no NUL, no control character" {
    const text = try getKeyText(c.XKB_KEY_eacute);
    try std.testing.expectEqualStrings("é", text.@"0"[0..text.@"1"]);
    try std.testing.expectError(error.ControlCharacter, getKeyText(c.XKB_KEY_BackSpace));
    try std.testing.expectError(error.ControlCharacter, getKeyText(c.XKB_KEY_Delete));
    try std.testing.expectError(error.ControlCharacter, getKeyText(c.XKB_KEY_Return));
    try std.testing.expectError(error.NoUTF8Representation, getKeyText(c.XKB_KEY_F1));
}

/// The XKB part alone, set up as on the calculator: fr, keypad option, compose
/// table of the C locale (en_US.UTF-8).
fn testKeyboard() !@This() {
    var im: @This() = undefined;
    const names: c.xkb_rule_names = .{ .model = "pc105", .layout = "fr", .variant = "", .options = "numpad:mac" };
    try im.initXkb(&names, "C");
    return im;
}

/// Press then release, as keyboardd types: what the key typed, if anything.
fn tap(self: *@This(), code: u16) !?KeyType {
    const keysym = try self.handleKey(code, 1);
    _ = try self.handleKey(code, 0);
    return keysym;
}

fn expectText(expected: []const u8, keysym: ?KeyType) !void {
    const text = try getKeyText(keysym orelse return error.TestExpectedKeysym);
    try std.testing.expectEqualStrings(expected, text.@"0"[0..text.@"1"]);
}
