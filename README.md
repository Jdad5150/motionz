# motionz

A high-performance HTTP server written in Zig for controlling a 3-axis robot arm via Raspberry Pi Picos over serial communication.

## Overview

motionz provides a RESTful API for real-time robot arm control and position monitoring. The server runs on a Raspberry Pi and communicates with three Raspberry Pi Picos (one per axis) via UART serial connections, enabling independent, concurrent axis movement with real-time status tracking.

## Architecture

```
┌─────────────┐         HTTP          ┌──────────────┐
│   Frontend  │ ◄──────────────────►  │  motionz     │
│   (Web UI)  │    JSON API           │  (Zig Server)│
└─────────────┘                       └──────┬───────┘
                                             │ UART
                                             │ (115200 baud)
                                    ┌────────┼───────┐
                                    │        │       │
                                ┌───▼──┐ ┌───▼──┐ ┌──▼───┐
                                │ Pico │ │ Pico │ │ Pico │
                                │  X   │ │  Y   │ │  Z   │
                                └──────┘ └──────┘ └──────┘
```

## Features

- **RESTful API**: Simple HTTP endpoints for position polling and movement commands
- **Per-Axis Control**: Independent X, Y, Z axis movement with individual status tracking
- **Thread-Safe**: Mutex-protected state management for concurrent operations
- **Real-Time Monitoring**: Poll current position and movement status at any frequency
- **Multi-Target Build**: Single build produces binaries for native, Pi 4 64-bit, and Pi 4 32-bit
- **Asynchronous Movement**: Non-blocking API returns immediately while axes move independently

## API Endpoints

### GET `/api/position`
Returns current robot state including position and per-axis status.

**Response:**
```json
{
  "position": { "x": 1000, "y": 2000, "z": 500 },
  "x_status": "moving",
  "y_status": "idle",
  "z_status": "moving",
  "status": "idle"
}
```

### POST `/api/move`
Send movement commands to one or more axes.

**Request:**
```json
{
  "x": 1000,
  "y": 2000,
  "z": 500
}
```

**Response:**
```json
{
  "success": true
}
```

**Notes:**
- All fields are optional - send only the axes you want to move
- Commands are non-blocking - the endpoint returns immediately
- Poll `/api/position` to monitor movement progress

## Serial Protocol

Communication with Picos uses a simple text-based protocol over UART (115200 baud, 8N1):

**Command Format:** `{VALUE}.0\n`
- Example: `1000.0\n` moves the axis to position 1000

**Response:** `200\n` when movement completes

## Hardware Configuration

| Axis | Device Path    | Pico Connection |
|------|----------------|-----------------|
| X    | /dev/ttyAMA0   | GPIO 14/15      |
| Y    | /dev/ttyAMA1   | GPIO 0/1        |
| Z    | /dev/ttyAMA2   | GPIO 4/5        |

## Building

### Prerequisites
- [Zig](https://ziglang.org/download/) (latest stable)
- Python 3.x (for test client)
- `requests` library: `pip install requests`

### Build

```bash
zig build
```

This produces binaries for all targets in `zig-out/`:

| Directory | Target |
|-----------|--------|
| `native/` | Your current machine |
| `aarch64/` | Raspberry Pi 4 (64-bit OS) |
| `arm/` | Raspberry Pi 4 (32-bit OS) |

### Deploying to Raspberry Pi

1. Build on your dev machine: `zig build`
2. Transfer the appropriate binary to your Pi:
   ```bash
   scp zig-out/aarch64/motionz pi@<pi-ip>:~/
   ```
3. Ensure your user has serial permissions (add to `dialout` group):
   ```bash
   sudo usermod -a -G dialout $USER
   ```
4. Run the server:
   ```bash
   ./motionz
   ```

## Testing

A Python test client is included for API validation:

```bash
python test_client.py
```

The test client will:
1. Display initial robot position
2. Send a movement command
3. Poll position in real-time, showing gradual movement progress
4. Display per-axis status updates

## Project Structure

```
motionz/
├── src/
│   └── main.zig          # Server implementation
├── build.zig             # Build configuration
├── build.zig.zon         # Dependencies (httpz)
├── test_client.py        # Python API test client
└── README.md
```

## State Management

The server maintains thread-safe robot state:

```zig
Robot {
  position: { x, y, z }      // Current position (i64)
  x_status: AxisStatus       // Per-axis status
  y_status: AxisStatus
  z_status: AxisStatus
  status: Status             // Overall system status
  mutex: Mutex               // Thread synchronization
}
```

**AxisStatus:** `idle` | `moving`  
**Status:** `idle` | `moving` | `startup` | `err`

## Future Enhancements

- [ ] Encoder feedback for real-time position updates during movement
- [ ] WebSocket support for push-based position streaming
- [ ] Movement queue for sequential operations
- [ ] Configurable acceleration/deceleration profiles
- [ ] Emergency stop endpoint
- [ ] Position limits and boundary checking
- [ ] Calibration/homing routines

## Dependencies

- [httpz](https://github.com/karlseguin/http.zig) - HTTP server framework

## License

MIT

## Author

Built with Zig for high-performance, low-latency robot control.
