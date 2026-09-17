import argparse
import time
import serial

parser = argparse.ArgumentParser(description="Control Pico GPIO15 relay over USB COM port")
parser.add_argument("port", help="Windows COM port, for example COM7")
parser.add_argument("command", choices=["on", "off", "toggle", "status"])
args = parser.parse_args()

commands = {"on": "1", "off": "0", "toggle": "T", "status": "?"}

with serial.Serial(args.port, 115200, timeout=2) as port:
    time.sleep(0.2)
    port.reset_input_buffer()
    port.write((commands[args.command] + "\r\n").encode("ascii"))
    port.flush()
    print(port.readline().decode("ascii", errors="replace").strip())
