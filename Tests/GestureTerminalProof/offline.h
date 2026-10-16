#include <ApplicationServices/ApplicationServices.h>

CGEventRef offline_event_create(CGEventSourceRef source);
void offline_event_post(CGEventTapLocation location, CGEventRef event);

// Compile-time interposition applies to the production C translation units.
// No code in either fixture can reach the real CGEventPost through these units.
#define CGEventCreate offline_event_create
#define CGEventPost offline_event_post
