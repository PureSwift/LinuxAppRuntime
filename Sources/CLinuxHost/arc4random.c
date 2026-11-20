// arc4random_buf, which an app's libapp.so leaves undefined (Embedded
// Swift's hashing calls it for its seed), where libc lacks it: musl, and
// glibc before 2.36 (Ubuntu 22.04's 2.35, which PortMaster ports build
// against). The runner exports it (exports.list), and its executable is
// searched first, so this is the definition the app binds to rather than
// one some other library in the process happens to have (on Alpine,
// Mesa pulls in libbsd's).

#include <features.h>

#if !defined(__GLIBC__) || !__GLIBC_PREREQ(2, 36)

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
