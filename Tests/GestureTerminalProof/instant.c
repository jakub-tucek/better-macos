#include "CStrafe.h"
#include <float.h>
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

static int checks;
static int failures;

static void expect(bool condition, const char *name) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL instant: %s\n", name); }
}

static void expect_properties(int index, int64_t phase, double sign) {
    expect(offline_phase(index) == phase, "phase order");
    expect(offline_type(index) == 30, "DockControl type");
    expect(offline_hid_type(index) == 23, "DockSwipe HID type");
    expect(offline_motion(index) == 1, "horizontal motion");
    expect(offline_progress(index) == sign * (double)FLT_TRUE_MIN, "signed progress");
    expect(offline_velocity_x(index) == sign * 2000, "X velocity");
    expect(offline_velocity_y(index) == sign * 2000, "Y velocity");
}

int main(void) {
    if (strafe_uses_iohid_payload()) {
        fprintf(stderr, "Fixture requires pre-27 allocation order; refusing different payload path.\n");
        return 2;
    }
    for (int right = 0; right <= 1; right++) {
        StrafeDirection direction = right ? StrafeDirectionRight : StrafeDirectionLeft;
        double sign = right ? 1.0 : -1.0;
        offline_reset(0);
        expect(strafe_post_switch_gesture(direction, 2000), "complete sequence succeeds");
        expect(offline_allocations() == 3 && offline_posts() == 3, "three complete posts");
        expect_properties(0, 1, sign);
        expect_properties(1, 2, sign);
        expect_properties(2, 4, sign);

        offline_reset(1);
        expect(!strafe_post_switch_gesture(direction, 2000), "began failure returns false");
        expect(offline_allocations() == 1 && offline_posts() == 0, "no continuation after failed began");

        offline_reset(2);
        expect(!strafe_post_switch_gesture(direction, 2000), "changed failure remains false after terminal attempt");
        expect(offline_allocations() == 3 && offline_posts() == 2, "terminal attempted after failed changed");
        expect_properties(0, 1, sign);
        expect_properties(1, 4, sign);

        offline_reset(3);
        expect(!strafe_post_switch_gesture(direction, 2000), "ended failure returns false");
        expect(offline_allocations() == 3 && offline_posts() == 2, "failed ended is not retried");
        expect_properties(0, 1, sign);
        expect_properties(1, 2, sign);
    }
    printf("%s instant-terminal-safety: %d checks, %d failures (both directions; phase failures and payload properties)\n",
           failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
