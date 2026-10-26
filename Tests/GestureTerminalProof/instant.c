#include "CStrafe.h"
#include <stdio.h>

void offline_reset(int);
int offline_allocations(void);
int offline_posts(void);
int64_t offline_phase(int);
int64_t offline_type(int);
int64_t offline_hid_type(int);
int64_t offline_motion(int);
double offline_progress(int);
double offline_velocity_x(int);
double offline_velocity_y(int);
int64_t offline_phase_alias(int);
bool offline_has_payload(int);
int32_t offline_payload_progress(int);
uint16_t offline_payload_flavor(int);
bool offline_payload_has_velocity(int);

static int checks;
static int failures;

static void expect(bool condition, const char *name) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL instant: %s\n", name); }
}

// macOS 27 posts each phase as an augmented dock swipe followed by a gesture
// companion. The augmented event's progress and velocity are sign-inverted.
static void expect_phase(int index, int64_t phase, double sign) {
    expect(offline_phase(index) == phase && offline_phase_alias(index) == phase, "phase order and alias");
    expect(offline_type(index) == 30, "DockControl type");
    expect(offline_hid_type(index) == 23, "DockSwipe HID type");
    expect(offline_motion(index) == 1, "horizontal motion");
    expect(offline_progress(index) == -sign * (double)1e-4f, "inverted minimal progress (stored as float)");
    expect(offline_velocity_x(index) == (phase == 4 ? -sign * 2000 : 0), "X velocity only when ended");
    expect(offline_velocity_y(index) == 0, "no Y velocity");
    expect(offline_has_payload(index) && offline_payload_flavor(index) == 3, "IOHID dock gesture payload");
    expect(offline_payload_progress(index) == (sign > 0 ? -6 : 6), "payload keeps progress direction");
    expect(offline_payload_has_velocity(index) == (phase == 4), "payload velocity only when ended");
    expect(offline_type(index + 1) == 29 && !offline_has_payload(index + 1), "plain gesture companion follows");
}

int main(void) {
    if (!strafe_uses_iohid_payload()) {
        fprintf(stderr, "Fixture requires macOS 27 augmented payloads; refusing different payload path.\n");
        return 2;
    }
    // Each phase allocates the swipe, then its companion, and posts both.
    for (int right = 0; right <= 1; right++) {
        StrafeDirection direction = right ? StrafeDirectionRight : StrafeDirectionLeft;
        double sign = right ? 1.0 : -1.0;
        offline_reset(0);
        expect(strafe_post_switch_gesture(direction, 2000), "complete sequence succeeds");
        expect(offline_allocations() == 6 && offline_posts() == 6, "three complete phases with companions");
        expect_phase(0, 1, sign);
        expect_phase(2, 2, sign);
        expect_phase(4, 4, sign);

        for (int fail_at = 1; fail_at <= 2; fail_at++) {
            offline_reset(fail_at);
            expect(!strafe_post_switch_gesture(direction, 2000), "began failure returns false");
            expect(offline_allocations() == fail_at && offline_posts() == 0, "no continuation after failed began");
        }

        for (int fail_at = 3; fail_at <= 4; fail_at++) {
            offline_reset(fail_at);
            expect(!strafe_post_switch_gesture(direction, 2000), "changed failure remains false after terminal attempt");
            expect(offline_allocations() == 6 - (fail_at == 3) && offline_posts() == 4, "terminal attempted after failed changed");
            expect_phase(0, 1, sign);
            expect_phase(2, 4, sign);
        }

        for (int fail_at = 5; fail_at <= 6; fail_at++) {
            offline_reset(fail_at);
            expect(!strafe_post_switch_gesture(direction, 2000), "ended failure returns false");
            expect(offline_allocations() == fail_at && offline_posts() == 4, "failed ended is not retried");
            expect_phase(0, 1, sign);
            expect_phase(2, 2, sign);
        }
    }
    printf("%s instant-terminal-safety: %d checks, %d failures (both directions; macOS 27 swipe and companion failures, payload properties)\n",
           failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
