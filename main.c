#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"

#define RELAY_GPIO 15
#define LED_GPIO 25
#define RELAY_ACTIVE_LEVEL 1  // Change to 0 for an active-low relay module.

static void relay_set(bool on) {
    bool level = on ? RELAY_ACTIVE_LEVEL : !RELAY_ACTIVE_LEVEL;
    gpio_put(RELAY_GPIO, level);
    gpio_put(LED_GPIO, on);
}

int main(void) {
    stdio_init_all();

    gpio_init(RELAY_GPIO);
    gpio_set_dir(RELAY_GPIO, GPIO_OUT);
    gpio_init(LED_GPIO);
    gpio_set_dir(LED_GPIO, GPIO_OUT);
    relay_set(false);

    // Give Windows time to enumerate the USB CDC COM port.
    sleep_ms(1500);

    printf("Pico relay controller ready\r\n");
    printf("Commands: 1/ON, 0/OFF, T/TOGGLE, ?/STATUS\r\n");

    bool relay_on = false;
    char command[32];
    size_t length = 0;

    while (true) {
        int ch = getchar_timeout_us(10000);
        if (ch == PICO_ERROR_TIMEOUT) {
            tight_loop_contents();
            continue;
        }

        if (ch == '\r' || ch == '\n') {
            if (length == 0) continue;
            command[length] = '\0';

            if (!strcmp(command, "1") || !strcmp(command, "ON") || !strcmp(command, "on")) {
                relay_on = true;
                relay_set(true);
                printf("RELAY ON\r\n");
            } else if (!strcmp(command, "0") || !strcmp(command, "OFF") || !strcmp(command, "off")) {
                relay_on = false;
                relay_set(false);
                printf("RELAY OFF\r\n");
            } else if (!strcmp(command, "T") || !strcmp(command, "t") ||
                       !strcmp(command, "TOGGLE") || !strcmp(command, "toggle")) {
                relay_on = !relay_on;
                relay_set(relay_on);
                printf("RELAY %s\r\n", relay_on ? "ON" : "OFF");
            } else if (!strcmp(command, "?") || !strcmp(command, "STATUS") || !strcmp(command, "status")) {
                printf("RELAY %s\r\n", relay_on ? "ON" : "OFF");
            } else {
                printf("ERROR: use 1, 0, ON, OFF, T, or ?\r\n");
            }
            length = 0;
        } else if (length < sizeof(command) - 1) {
            command[length++] = (char)ch;
        } else {
            length = 0;
            printf("ERROR: command too long\r\n");
        }
    }
}
