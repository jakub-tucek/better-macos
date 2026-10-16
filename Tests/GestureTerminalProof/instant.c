#include "CStrafe.h"
#include <stdio.h>
#include <string.h>

void offline_reset(int);
int offline_allocations(void);
int offline_posts(void);
int64_t offline_phase(int);

int main(int argc, char **argv) {
    const bool require_safety = argc == 2 && strcmp(argv[1], "--require-safety") == 0;
    if (strafe_uses_iohid_payload()) {
        fprintf(stderr, "Fixture requires pre-27 allocation order; refusing different payload path.\n");
        return 2;
    }
    offline_reset(0);
    bool success = strafe_post_switch_gesture(StrafeDirectionRight, 2000);
    if (!success || offline_posts() != 3 || offline_phase(0) != 1 ||
        offline_phase(1) != 2 || offline_phase(2) != 4) { return 2; }
    printf("CONTROL instant: began/changed/ended posted to fake sink\n");

    offline_reset(2); // began allocated and fake-posted; changed allocation fails.
    success = strafe_post_switch_gesture(StrafeDirectionRight, 2000);
    const bool reproduced = !success && offline_allocations() == 2 &&
        offline_posts() == 1 && offline_phase(0) == 1;
    printf("%s instant: allocations=%d posts=%d terminal_attempted=%s result=%s\n",
           reproduced ? "REPRODUCED" : "CHANGED", offline_allocations(), offline_posts(),
           offline_allocations() >= 3 ? "true" : "false", success ? "success" : "failure");
    const bool safe_changed_failure = offline_allocations() >= 3 && !success;

    offline_reset(3); // Terminal allocation fails after began and changed fake-posts.
    success = strafe_post_switch_gesture(StrafeDirectionRight, 2000);
    const bool terminal_failure = !success && offline_allocations() == 3 && offline_posts() == 2;
    printf("%s instant-ended-failure: allocations=%d posts=%d terminal_attempted=true result=%s\n",
           terminal_failure ? "REPRODUCED" : "CHANGED", offline_allocations(), offline_posts(), success ? "success" : "failure");
    // Characterization passes only for the observed holes. Opt-in safety assertion is red.
    return require_safety ? (safe_changed_failure ? 0 : 1) : (reproduced && terminal_failure ? 0 : 2);
}
