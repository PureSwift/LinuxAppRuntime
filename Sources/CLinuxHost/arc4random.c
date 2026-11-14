// What app slices need from libc that older glibc lacks. Ubuntu 22.04's
// glibc 2.35, which PortMaster ports build against, has no arc4random_buf
// (2.36 added it); Embedded Swift's hashing calls it for its seed.

#include <features.h>

#if defined(__GLIBC__) && !__GLIBC_PREREQ(2, 36)

#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/random.h>

void arc4random_buf(void *buffer, size_t size) {
    unsigned char *bytes = buffer;
    while (size > 0) {
        ssize_t count = getrandom(bytes, size, 0);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            abort();
        }
        bytes += count;
        size -= (size_t)count;
    }
}

#endif
