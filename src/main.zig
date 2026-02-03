const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const server_title =
    \\___  ___      _   _              ______
    \\|  \/  |     | | (_)            |___  /
    \\| .  . | ___ | |_ _  ___  _ __     / /
    \\| |\/| |/ _ \| __| |/ _ \| '_ \   / /
    \\| |  | | (_) | |_| | (_) | | | |./ /___
    \\\_|  |_/\___/ \__|_|\___/|_| |_|\_____/
;

const AxisStatus = enum {
    idle,
    moving,
};

const Robot = struct {
    position: Position,
    x_status: AxisStatus = .idle,
    y_status: AxisStatus = .idle,
    z_status: AxisStatus = .idle,
    status: Status = .startup,
    mutex: std.Thread.Mutex = .{},

    // Required by httpz for WebSocket support
    pub const WebsocketHandler = Handler.WebsocketHandler;

    const Status = enum {
        idle,
        moving,
        startup,
        err,
    };

    fn isMoving(self: *const Robot) bool {
        return self.x_status == .moving or self.y_status == .moving or self.z_status == .moving;
    }
};

const Position = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
};

const Handler = struct {
    const WebsocketContext = struct {
        robot: *Robot,
    };
    pub const WebsocketHandler = struct {
        conn: *websocket.Conn,
        robot: *Robot,

        pub fn init(conn: *websocket.Conn, ctx: WebsocketContext) !WebsocketHandler {
            return .{
                .conn = conn,
                .robot = ctx.robot,
            };
        }

        pub fn clientMessage(self: *WebsocketHandler, data: []const u8) !void {
            if (std.mem.eql(u8, data, "ping")) {
                try self.sendPosition();
            }
        }
        pub fn sendPosition(self: *WebsocketHandler) !void {
            // Lock, copy snapshot, unlock - keeps lock duration minimal
            self.robot.mutex.lock();
            const snapshot = .{
                .x = self.robot.position.x,
                .y = self.robot.position.y,
                .z = self.robot.position.z,
                .x_status = @tagName(self.robot.x_status),
                .y_status = @tagName(self.robot.y_status),
                .z_status = @tagName(self.robot.z_status),
                .status = @tagName(self.robot.status),
            };
            self.robot.mutex.unlock();

            // Format and send outside the lock
            var buffer: [256]u8 = undefined;
            const json: []u8 = try std.fmt.bufPrint(&buffer, "{{\"position\":{{\"x\":{d},\"y\":{d},\"z\":{d}}},\"x_status\":\"{s}\",\"y_status\":\"{s}\",\"z_status\":\"{s}\",\"status\":\"{s}\"}}", .{
                snapshot.x,
                snapshot.y,
                snapshot.z,
                snapshot.x_status,
                snapshot.y_status,
                snapshot.z_status,
                snapshot.status,
            });
            try self.conn.write(json);
        }
    };
};

fn configureSerialPort(device: []const u8) void {
    const fd = c.open(device.ptr, c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) {
        std.log.warn("Cannot open serial port {s} for configuration (may not exist)", .{device});
        return;
    }
    defer _ = c.close(fd);

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

    std.log.info("Configured {s} at 115200 baud", .{device});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Print the banner directly to stdout for proper formatting
    const stdout = std.posix.STDOUT_FILENO;
    _ = std.posix.write(stdout, server_title) catch {};
    _ = std.posix.write(stdout, "\n") catch {};

    std.log.info("Starting motionz server...", .{});

    // Configure serial ports at startup
    const serial_ports = [_][]const u8{ "/dev/serial0", "/dev/ttyAMA2", "/dev/ttyAMA3" };
    for (serial_ports) |port| {
        configureSerialPort(port);
    }

    var robot: Robot = .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .status = .startup };

    var server = try httpz.Server(*Robot).init(allocator, .{ .port = 5882, .address = "0.0.0.0" }, &robot);
    defer {
        std.log.info("Shutting down server...", .{});
        server.stop();
        server.deinit();
    }

    // Set to idle after startup
    robot.status = .idle;

    var router = try server.router(.{});
    router.get("/api/position", getPosition, .{});
    router.post("/api/move", sendMove, .{});
    router.get("/ws", upgradeWebsocket, .{});

    std.log.info("Server listening on http://0.0.0.0:5882", .{});
    std.log.info("Routes: GET /api/position, POST /api/move", .{});

    // blocks
    try server.listen();
}

fn upgradeWebsocket(robot: *Robot, req: *httpz.Request, res: *httpz.Response) !void {
    const upgraded: bool = try httpz.upgradeWebsocket(Handler.WebsocketHandler, req, res, Handler.WebsocketContext{ .robot = robot });
    if (!upgraded) {
        res.status = 400;
        res.body = "Invalid websocket handshake";
        return;
    }
}

fn getPosition(robot: *Robot, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    std.log.info("GET /api/position - pos=({d},{d},{d}) status={s}", .{
        robot.position.x,
        robot.position.y,
        robot.position.z,
        @tagName(robot.status),
    });
    res.status = 200;
    try res.json(.{
        .position = robot.position,
        .x_status = robot.x_status,
        .y_status = robot.y_status,
        .z_status = robot.z_status,
        .status = robot.status,
    }, .{});
}

const MoveCommand = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    z: ?f64 = null,
};

fn sendMove(robot: *Robot, req: *httpz.Request, res: *httpz.Response) !void {
    const body = try req.json(MoveCommand) orelse {
        std.log.warn("POST /api/move - missing JSON body", .{});
        res.status = 400;
        try res.json(.{ .err = "Missing JSON body" }, .{});
        return;
    };

    std.log.info("POST /api/move - x={?d} y={?d} z={?d}", .{ body.x, body.y, body.z });

    // Send commands and update status to moving
    if (body.x) |x| {
        robot.x_status = .moving;
        sendToAxis(robot, "/dev/serial0", 'X', x) catch |err| {
            std.log.err("Failed to send X command: {}", .{err});
        };
    }
    if (body.y) |y| {
        robot.y_status = .moving;
        sendToAxis(robot, "/dev/ttyAMA2", 'Y', y) catch |err| {
            std.log.err("Failed to send Y command: {}", .{err});
        };
    }
    if (body.z) |z| {
        robot.z_status = .moving;
        sendToAxis(robot, "/dev/ttyAMA3", 'Z', z) catch |err| {
            std.log.err("Failed to send Z command: {}", .{err});
        };
    }

    res.status = 200;
    try res.json(.{ .success = true }, .{});
}

fn sendToAxis(robot: *Robot, device: []const u8, axis: u8, value: f64) !void {
    std.log.debug("Opening serial port {s} for axis {c}", .{ device, axis });

    // Open serial port
    const fd = c.open(device.ptr, c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) {
        std.log.err("Cannot open serial port {s}", .{device});
        return error.CannotOpenSerial;
    }
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
    const msg = try std.fmt.bufPrint(&buf, "{d}\n", .{value});

    const bytes_written = c.write(fd, msg.ptr, msg.len);
    std.log.debug("Sent {s} to {c} axis ({d} bytes)", .{ msg[0 .. msg.len - 1], axis, bytes_written });

    // TODO: Wait for Pico response (e.g. "200\n") before updating status
    // Update position and status immediately (fire and forget)
    robot.mutex.lock();
    defer robot.mutex.unlock();

    switch (axis) {
        'X' => {
            robot.position.x = value;
            robot.x_status = .idle;
            std.log.info("X axis moved to {d}", .{value});
        },
        'Y' => {
            robot.position.y = value;
            robot.y_status = .idle;
            std.log.info("Y axis moved to {d}", .{value});
        },
        'Z' => {
            robot.position.z = value;
            robot.z_status = .idle;
            std.log.info("Z axis moved to {d}", .{value});
        },
        else => {},
    }
}
