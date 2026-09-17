cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(pico_relay_com C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

set(PICO_NO_PICOTOOL OFF)

pico_sdk_init()

add_executable(pico_relay_com main.c)

target_link_libraries(pico_relay_com pico_stdlib)

# Use the Pico USB connector as a virtual COM port.
pico_enable_stdio_usb(pico_relay_com 1)
pico_enable_stdio_uart(pico_relay_com 0)

pico_add_extra_outputs(pico_relay_com)
