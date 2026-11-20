#include "CLinuxHost.h"
#include <sys/prctl.h>

void clinuxhost_set_process_name(const char *name) {
    prctl(PR_SET_NAME, (unsigned long)name, 0, 0, 0);
}
