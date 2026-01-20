const std = @import("std");
const httpz = @import("httpz");

// Only import C headers on Linux
const c = if (@import("builtin").os.tag == .linux) @cImport({
    // Uncomment below line when on Linux
    //@cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
}) else struct {};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{ .port = 5882 }, {});
    defer {
        // clean shutdown, finishes serving any live request
        server.stop();
        server.deinit();
    }

    //
    var router = try server.router(.{});
    router.get("/api/user/:id", getUser, .{});
    router.post("/api/move", sendMove, .{});

    // blocks
    try server.listen();
}

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    try res.json(.{ .id = req.param("id").?, .name = "Teg" }, .{});
}

const MoveCommand = struct {
    x: ?i64 = null,
    y: ?i64 = null,
    z: ?i64 = null,
};

fn sendMove(req: *httpz.Request, res: *httpz.Response) !void {
    const body = try req.json(MoveCommand) orelse {
        res.status = 400;
        try res.json(.{ .err = "Missing JSON body" }, .{});
        return;
    };

    // Send to each axis Pico if coordinate is provided
    if (body.x) |x| {
        try sendToAxis("/dev/ttyAMA0", 'X', x);
    }
    if (body.y) |y| {
        try sendToAxis("/dev/ttyAMA1", 'Y', y);
    }
    if (body.z) |z| {
        try sendToAxis("/dev/ttyAMA2", 'Z', z);
    }

    res.status = 200;
    try res.json(.{ .success = true }, .{});
}

fn sendToAxis(device: []const u8, axis: u8, value: i64) !void {
    if (@import("builtin").os.tag != .linux) {
        // Mock for non-Linux (testing on Windows)
        std.debug.print("[MOCK] Would send to {s}: {c}:{d}\n", .{ device, axis, value });
        return;
    }

    // Open serial port
    const fd = c.open(device.ptr, c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) return error.CannotOpenSerial;
    defer _ = c.close(fd);

    // Configure serial port
    var tty: c.termios = undefined;
    _ = c.tcgetattr(fd, &tty);

    // Set baud rate to 115200
    _ = c.cfsetospeed(&tty, c.B115200);
    _ = c.cfsetispeed(&tty, c.B115200);

    // 8N1 mode (8 data bits, no parity, 1 stop bit)
    tty.c_cflag = (tty.c_cflag & ~@as(c_uint, c.PARENB)) | c.CS8 | c.CREAD | c.CLOCAL;
    tty.c_cflag &= ~@as(c_uint, c.CSTOPB);
    tty.c_cflag &= ~@as(c_uint, c.CRTSCTS);

    // Raw mode
    tty.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO | c.ECHOE | c.ISIG);
    tty.c_iflag &= ~@as(c_uint, c.IXON | c.IXOFF | c.IXANY);
    tty.c_oflag &= ~@as(c_uint, c.OPOST);

    // Apply settings
    _ = c.tcsetattr(fd, c.TCSANOW, &tty);

    // Send command: "X:100\n" or "Y:200\n" or "Z:50\n"
    var buf: [32]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{c}:{d}\n", .{ axis, value });
    _ = c.write(fd, msg.ptr, msg.len);
}
