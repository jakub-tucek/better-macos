# Fix macOS

Terms for coordinating reversible system changes and safe application exit.

## Language

**Quit attempt**:
A request to exit after active system changes have been made safe. A canceled attempt leaves the application available for further use; approval lasts through shutdown.
_Avoid_: Clipboard termination

**Host admission**:
Permission to begin a new settings or feature action while the application remains available for use. Admission is closed during a quit attempt and reopened when that attempt is canceled.
_Avoid_: UI disabled state

**Verified window movement**:
A requested position and size change whose resulting geometry has been read back and matches the request. Failure does not imply that the window stayed unchanged.
_Avoid_: Atomic window move
