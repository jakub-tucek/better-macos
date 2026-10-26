#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

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
static int64_t posted_phase_aliases[32];
static bool posted_payloads[32];
static int32_t posted_payload_progress[32];
static uint16_t posted_payload_flavors[32];
static bool posted_payload_velocities[32];

// Finds a little-endian record header in the event's serialized form.
static const uint8_t *find_record(CFDataRef data, const uint8_t *header, size_t length) {
    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex total = CFDataGetLength(data);
    for (CFIndex offset = 0; offset + (CFIndex)length <= total; offset++) {
        if (memcmp(bytes + offset, header, length) == 0) { return bytes + offset; }
    }
    return NULL;
}

// Records the macOS 27 IOHID payload: a 40-byte fluid-touch gesture record
// (type 23, phase in the top options byte) and, when present, a velocity record.
static void record_payload(int index, CGEventRef event, int64_t phase) {
    posted_payloads[index] = false;
    posted_payload_velocities[index] = false;
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) { return; }
    const uint8_t fluid_header[12] = {40, 0, 0, 0, 23, 0, 0, 0, 0, 0, 0, (uint8_t)phase};
    const uint8_t velocity_header[8] = {28, 0, 0, 0, 9, 0, 0, 0};
    const uint8_t *fluid = find_record(data, fluid_header, sizeof fluid_header);
    if (fluid) {
        posted_payloads[index] = true;
        memcpy(&posted_payload_flavors[index], fluid + 34, sizeof(uint16_t));
        memcpy(&posted_payload_progress[index], fluid + 36, sizeof(int32_t));
    }
    posted_payload_velocities[index] = find_record(data, velocity_header, sizeof velocity_header) != NULL;
    CFRelease(data);
}

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
        posted_phase_aliases[posted_count] = CGEventGetIntegerValueField(event, (CGEventField)134);
        record_payload(posted_count, event, posted_phases[posted_count]);
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
int64_t offline_phase_alias(int index) { return posted_phase_aliases[index]; }
bool offline_has_payload(int index) { return posted_payloads[index]; }
int32_t offline_payload_progress(int index) { return posted_payload_progress[index]; }
uint16_t offline_payload_flavor(int index) { return posted_payload_flavors[index]; }
bool offline_payload_has_velocity(int index) { return posted_payload_velocities[index]; }
