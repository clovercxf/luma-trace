#include "SystemLock.h"
#include <sys/file.h>
int shiguang_try_exclusive_lock(int descriptor) {
    return flock(descriptor, LOCK_EX | LOCK_NB);
}
