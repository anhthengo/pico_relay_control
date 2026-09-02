# Raspberry Pi Pico GPIO15 relay controller

This Pico SDK project exposes the Pico USB connector as a Windows virtual COM port. Send a line containing `1` or `ON` to assert GPIO15, and `0` or `OFF` to deassert it. The Pico's built-in LED on GPIO25 indicates when the relay is on.

## Wiring

For a 3.3 V relay module whose input is compatible with 3.3 V logic:

- Pico pin 21, GP15 -> relay IN
- Pico pin 36, 3V3(OUT) -> relay VCC
- Pico GND -> relay GND

Do not power a bare relay coil directly from GP15. Use a transistor/MOSFET driver and flyback diode. Confirm the relay coil current is within the Pico 3.3 V supply budget.

## Build on Windows

From this project directory:
Only works on command prompt, not powershell

```cmd
set PICO_SDK_PATH=D:\rasberrypi\pico-sdk
cmake -S . -B build -G Ninja -DPICO_BOARD=pico
cmake --build build
```
In PowerShell, set the environment variable with `$env:` instead:

```powershell
$env:PICO_SDK_PATH = 'D:\rasberrypi\pico-sdk'
cmake -S . -B build -G Ninja -DPICO_BOARD=pico
cmake --build build
```

Set it permanently in Windows user environment
[Environment]::SetEnvironmentVariable(
  "PICO_SDK_PATH",
  "D:\rasberrypi\pico-sdk",
  "User"
)
or modify in PowerShell only:
notepad $PROFILE
Then run 

.\build\elf2uf2.exe -v .\build\pico_relay_com.elf .\build\pico_relay_com.uf2

The firmware is `build\pico_relay_com.uf2`.

If a stale build directory was previously configured for NMake, delete `build` and rerun the commands above.

## Flash

1. Disconnect the Pico.
2. Hold BOOTSEL while reconnecting USB.
3. Copy `build\pico_relay_com.uf2` to the `RPI-RP2` drive.
4. The Pico restarts and Windows assigns a COM port. Find it under Device Manager > Ports (COM & LPT).

## Control from a terminal

Open PuTTY, Tera Term, or RealTerm using the assigned COM port. The nominal baud setting can be 115200; USB CDC does not use the Pico UART pins.

Send a command followed by Enter:

- `1` or `ON`: relay on
- `0` or `OFF`: relay off
- `T`: toggle
- `?`: status

## Control from Python

```cmd
py -m pip install pyserial
py host_control.py COM7 on
py host_control.py COM7 off
py host_control.py COM7 status
```

Replace `COM7` with the port shown in Device Manager.
