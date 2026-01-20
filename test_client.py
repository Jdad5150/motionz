import requests
import time
import json

BASE_URL = "http://localhost:5882"

def get_position():
    """Poll the current position and status"""
    try:
        resp = requests.get(f"{BASE_URL}/api/position")
        return resp.json()
    except Exception as e:
        print(f"Error getting position: {e}")
        return None

def send_move(x=None, y=None, z=None):
    """Send move command"""
    payload = {}
    if x is not None:
        payload['x'] = x
    if y is not None:
        payload['y'] = y
    if z is not None:
        payload['z'] = z
    
    try:
        resp = requests.post(f"{BASE_URL}/api/move", json=payload)
        return resp.json()
    except Exception as e:
        print(f"Error sending move: {e}")
        return None

def main():
    print("=== Robot Arm Test Client ===\n")
    
    # Initial position
    print("Initial position:")
    pos = get_position()
    print(json.dumps(pos, indent=2))
    print()
    
    # Send move command
    print("Sending move command: X=1000, Y=2000, Z=5000")
    result = send_move(x=1000, y=2000, z=5000)
    print(f"Move result: {result}\n")
    
    # Poll position in real-time
    print("Polling position (Ctrl+C to stop):")
    print("-" * 60)
    
    try:
        while True:
            pos = get_position()
            if pos:
                status_str = f"Status: {pos.get('status', 'unknown')}"
                x_status = f"X: {pos['position']['x']} ({pos.get('x_status', 'unknown')})"
                y_status = f"Y: {pos['position']['y']} ({pos.get('y_status', 'unknown')})"
                z_status = f"Z: {pos['position']['z']} ({pos.get('z_status', 'unknown')})"
                
                line = f"{status_str} | {x_status} | {y_status} | {z_status}"
                print(f"\r{line:<80}", end="", flush=True)  # Pad to 80 chars to clear old text
            
            time.sleep(0.1)  # Poll faster to see more granular updates
    except KeyboardInterrupt:
        print("\n\nStopped polling.")

if __name__ == "__main__":
    main()
