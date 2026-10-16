#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

static int allocations;
static int fail_allocation;
static int posted_count;
static int64_t posted_phases[32];
static int64_t posted_types[32];
static int64_t posted_hid_types[32];
static int64_t posted_motions[32];
static double posted_progress[32];
static double posted_velocity_x[32];
static double posted_velocity_y[32];

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
        posted_phases[posted_count] = CGEventGetIntegerValueField(event, (CGEventField)132);
        posted_types[posted_count] = CGEventGetIntegerValueField(event, (CGEventField)55);
        posted_hid_types[posted_count] = CGEventGetIntegerValueField(event, (CGEventField)110);
        posted_motions[posted_count] = CGEventGetIntegerValueField(event, (CGEventField)123);
        posted_progress[posted_count] = CGEventGetDoubleValueField(event, (CGEventField)124);
        posted_velocity_x[posted_count] = CGEventGetDoubleValueField(event, (CGEventField)129);
        posted_velocity_y[posted_count] = CGEventGetDoubleValueField(event, (CGEventField)130);
        posted_count++;
    }
}

int offline_allocations(void) { return allocations; }
int offline_posts(void) { return posted_count; }
int64_t offline_phase(int index) { return posted_phases[index]; }
int64_t offline_type(int index) { return posted_types[index]; }
int64_t offline_hid_type(int index) { return posted_hid_types[index]; }
int64_t offline_motion(int index) { return posted_motions[index]; }
double offline_progress(int index) { return posted_progress[index]; }
double offline_velocity_x(int index) { return posted_velocity_x[index]; }
double offline_velocity_y(int index) { return posted_velocity_y[index]; }
