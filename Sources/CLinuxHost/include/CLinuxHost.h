// What the runner's process supplies that libc may not, and what Swift
// can't call itself.
#include <stddef.h>

/// Names the process for `ps` and `top` (`PR_SET_NAME`), which keep 15
/// bytes of it: every app runs in the same runner, and is shown by its own
/// name. prctl is variadic, so Swift can't call it.
void clinuxhost_set_process_name(const char *name);
