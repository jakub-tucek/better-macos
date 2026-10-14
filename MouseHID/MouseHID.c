#include "MouseHID.h"
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hid/IOHIDEventServiceKeys.h>
// The SDK still exports these deprecated APIs. Keep warnings confined to this
// compatibility boundary, and always use the mouse key, never generic pointer.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
IOReturn MouseHIDGetAcceleration(io_connect_t connection, double *value) {
    return IOHIDGetAccelerationWithKey(connection, CFSTR(kIOHIDMouseAccelerationTypeKey), value);
}
IOReturn MouseHIDSetAcceleration(io_connect_t connection, double value) {
    return IOHIDSetAccelerationWithKey(connection, CFSTR(kIOHIDMouseAccelerationTypeKey), value);
}
#pragma clang diagnostic pop
