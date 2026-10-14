#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
IOReturn MouseHIDGetAcceleration(io_connect_t connection, double *value);
IOReturn MouseHIDSetAcceleration(io_connect_t connection, double value);
