const std = @import("std");
const httpz = @import("httpz");

// Only import C headers on Linux
const c = if (@import("builtin").os.tag == .linux) @cImport({
    // Uncomment below line when on Linux
    //@cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
}) else struct {};

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
    x: i64 = 0,
    y: i64 = 0,
    z: i64 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var robot: Robot = .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .status = .startup };

    var server = try httpz.Server(*Robot).init(allocator, .{ .port = 5882 }, &robot);
    defer {
        // clean shutdown, finishes serving any live request
        server.stop();
        server.deinit();
    }

    // Set to idle after startup
    robot.status = .idle;

    //
    var router = try server.router(.{});
    router.get("/api/position", getPosition, .{});
    router.post("/api/move", sendMove, .{});

    // blocks
    try server.listen();
}

fn getPosition(robot: *Robot, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
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
    x: ?i64 = null,
    y: ?i64 = null,
    z: ?i64 = null,
};

fn sendMove(robot: *Robot, req: *httpz.Request, res: *httpz.Response) !void {
    const body = try req.json(MoveCommand) orelse {
        res.status = 400;
        try res.json(.{ .err = "Missing JSON body" }, .{});
        return;
    };

    // Send commands and update status to moving
    if (body.x) |x| {
        robot.x_status = .moving;
        try sendToAxis(robot, "/dev/ttyAMA0", 'X', x);
    }
    if (body.y) |y| {
        robot.y_status = .moving;
        try sendToAxis(robot, "/dev/ttyAMA1", 'Y', y);
    }
    if (body.z) |z| {
        robot.z_status = .moving;
        try sendToAxis(robot, "/dev/ttyAMA2", 'Z', z);
    }

    res.status = 200;
    try res.json(.{ .success = true }, .{});
}

fn sendToAxis(robot: *Robot, device: []const u8, axis: u8, value: i64) !void {
    // ============================================================================
    // WINDOWS MOCK CODE - Remove this entire block when deploying to Linux/Pi
    // ============================================================================
    if (@import("builtin").os.tag != .linux) {
        std.debug.print("[MOCK] Would send to {s}: {c}:{d}\n", .{ device, axis, value });

        // Spawn thread to simulate gradual movement
        const Context = struct {
            robot: *Robot,
            axis: u8,
            target: i64,
        };

        const ctx = try std.heap.page_allocator.create(Context);
        ctx.* = .{ .robot = robot, .axis = axis, .target = value };

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(context: *Context) void {
                defer std.heap.page_allocator.destroy(context);

                const start = switch (context.axis) {
                    'X' => context.robot.position.x,
                    'Y' => context.robot.position.y,
                    'Z' => context.robot.position.z,
                    else => 0,
                };

                const steps = 50;
                const step_size = @divTrunc(context.target - start, steps);

                var i: i32 = 0;
                while (i < steps) : (i += 1) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);

                    context.robot.mutex.lock();
                    switch (context.axis) {
                        'X' => context.robot.position.x += step_size,
                        'Y' => context.robot.position.y += step_size,
                        'Z' => context.robot.position.z += step_size,
                        else => {},
                    }
                    context.robot.mutex.unlock();
                }

                // Final position and mark as idle
                context.robot.mutex.lock();
                defer context.robot.mutex.unlock();

                switch (context.axis) {
                    'X' => {
                        context.robot.position.x = context.target;
                        context.robot.x_status = .idle;
                    },
                    'Y' => {
                        context.robot.position.y = context.target;
                        context.robot.y_status = .idle;
                    },
                    'Z' => {
                        context.robot.position.z = context.target;
                        context.robot.z_status = .idle;
                    },
                    else => {},
                }
            }
        }.run, .{ctx});

        thread.detach();
        return;
    }
    // ============================================================================
    // END WINDOWS MOCK CODE
    // ============================================================================

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

    // Read response (blocking until Pico sends "200")
    var response: [16]u8 = undefined;
    const bytes_read = c.read(fd, &response, response.len);

    // Update position and status when done
    if (bytes_read > 0) {
        robot.mutex.lock();
        defer robot.mutex.unlock();

        switch (axis) {
            'X' => {
                robot.position.x = value;
                robot.x_status = .idle;
            },
            'Y' => {
                robot.position.y = value;
                robot.y_status = .idle;
            },
            'Z' => {
                robot.position.z = value;
                robot.z_status = .idle;
            },
            else => {},
        }
    }
}
