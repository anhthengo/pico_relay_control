#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"

#define RELAY_GPIO 15
#define RELAY_GPIO2 14
#define RELAY_GPIO3 26
#define RELAY_GPIO4 27
#define LED_GPIO 25
#define GPIO28_INT 28
#define GPIO29_OUT 29
#define RELAY_ACTIVE_LEVEL 1  // Change to 0 for an active-low relay module.
#define GPIO28_CHECK_DELAY_MS 100  // Delay before checking GPIO28 after relay is turned on.

static volatile uint32_t relay_on_counter = 0;
static volatile uint32_t success_count = 0;
static volatile uint32_t fail_count = 0;
static volatile bool delayed_c_check_pending = false;
static volatile absolute_time_t delayed_c_check_time = 0;
static volatile bool relay_counter_enabled = true;

static void set_relay_counter_enabled(bool enabled) {
    relay_counter_enabled = enabled;
    gpio_put(GPIO29_OUT, enabled ? 1 : 0);
}

static void relay_set(bool on) {
    bool level = on ? RELAY_ACTIVE_LEVEL : !RELAY_ACTIVE_LEVEL;
    gpio_put(RELAY_GPIO, level);
    gpio_put(RELAY_GPIO2, level);
    gpio_put(RELAY_GPIO3, !level);
    gpio_put(RELAY_GPIO4, !level);
    gpio_put(LED_GPIO, on);
}

static void command_c_check(bool relay_on) {
    if (relay_counter_enabled == false) {
        printf("RELAY ON count disabled\r\n");
        return;
    }
    if (relay_on && gpio_get(GPIO28_INT)) {
        success_count++;
    } else {
        fail_count++;
    }
    set_relay_counter_enabled(false);
    printf("success_count=%lu fail_count=%lu\r\n",
           (unsigned long)success_count,
           (unsigned long)fail_count);
}

int main(void) {
    stdio_init_all();

    gpio_init(RELAY_GPIO);
    gpio_set_dir(RELAY_GPIO, GPIO_OUT);
    gpio_init(RELAY_GPIO2);
    gpio_set_dir(RELAY_GPIO2, GPIO_OUT);
    gpio_init(RELAY_GPIO3);
    gpio_set_dir(RELAY_GPIO3, GPIO_OUT);
    gpio_init(RELAY_GPIO4);
    gpio_set_dir(RELAY_GPIO4, GPIO_OUT);
    gpio_init(LED_GPIO);
    gpio_set_dir(LED_GPIO, GPIO_OUT);

    gpio_init(GPIO29_OUT);
    gpio_set_dir(GPIO29_OUT, GPIO_OUT);

    gpio_init(GPIO28_INT);
    gpio_set_dir(GPIO28_INT, GPIO_IN);
    gpio_pull_down(GPIO28_INT);

    set_relay_counter_enabled(relay_counter_enabled);
    relay_set(false);

    // Give Windows time to enumerate the USB CDC COM port.
    sleep_ms(1500);

    printf("Pico relay controller ready\r\n");
    printf("Commands: 1/ON, 0/OFF, T/TOGGLE, ?/STATUS, c\r\n");

    bool relay_on = false;
    char command[32];
    size_t length = 0;

    while (true) {
        if (delayed_c_check_pending && absolute_time_diff_us(delayed_c_check_time, get_absolute_time()) >= GPIO28_CHECK_DELAY_MS * 1000) {
            delayed_c_check_pending = false;
            command_c_check(relay_on);
        }

        int ch = getchar_timeout_us(1000);
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
                if (relay_counter_enabled == false) {
                    relay_on_counter++;
                    set_relay_counter_enabled(true);
                    delayed_c_check_pending = true;
                    delayed_c_check_time = get_absolute_time();
                    printf("RELAY ON count=%lu\r\n", (unsigned long)relay_on_counter);
                }
            } else if (!strcmp(command, "0") || !strcmp(command, "OFF") || !strcmp(command, "off")) {
                relay_on = false;
                set_relay_counter_enabled(false);
                delayed_c_check_pending = false;
                relay_set(false);
                printf("RELAY OFF\r\n");
            } else if (!strcmp(command, "T") || !strcmp(command, "t") ||
                       !strcmp(command, "TOGGLE") || !strcmp(command, "toggle")) {
                relay_on = !relay_on;
                relay_set(relay_on);
                if (relay_on) {
                    relay_on_counter++;
                    set_relay_counter_enabled(true);
                    delayed_c_check_pending = true;
                    delayed_c_check_time = get_absolute_time();
                    printf("RELAY ON count=%lu\r\n", (unsigned long)relay_on_counter);
                } else {
                    set_relay_counter_enabled(false);
                    delayed_c_check_pending = false;
                    printf("RELAY OFF\r\n");
                }
            } else if (!strcmp(command, "?") || !strcmp(command, "STATUS") || !strcmp(command, "status")) {
                printf("RELAY %s count=%lu\r\n", relay_on ? "ON" : "OFF", (unsigned long)relay_on_counter);
            } else if (!strcmp(command, "C") || !strcmp(command, "c")) {
                command_c_check(relay_on);
            } else {
                printf("ERROR: use 1, 0, ON, OFF, T, C, or ?\r\n");
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
