#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

static int allocations;
static int fail_allocation;
static int posted_count;
static int64_t posted_phases[32];

void offline_reset(int fail_at) {
    allocations = 0;
    fail_allocation = fail_at;
    posted_count = 0;
}

CGEventRef offline_event_create(CGEventSourceRef source) {
    allocations++;
    if (allocations == fail_allocation) { return NULL; }
    // Allocates an unposted in-memory event. Never creates a tap or posts input.
    return CGEventCreate(source);
}

void offline_event_post(CGEventTapLocation location, CGEventRef event) {
    (void)location;
    if (posted_count < 32) {
        posted_phases[posted_count++] = CGEventGetIntegerValueField(event, (CGEventField)132);
    }
}

int offline_allocations(void) { return allocations; }
int offline_posts(void) { return posted_count; }
int64_t offline_phase(int index) { return posted_phases[index]; }
