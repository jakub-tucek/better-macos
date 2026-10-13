#ifndef STRAFE_IOHID_PAYLOAD_H
#define STRAFE_IOHID_PAYLOAD_H
#include <ApplicationServices/ApplicationServices.h>

// Returns a new event with the macOS 27 IOHID payload, or NULL on failure.
// The input is borrowed; the caller owns the returned event.
CGEventRef strafe_create_augmented_event(CGEventRef event);
#endif
