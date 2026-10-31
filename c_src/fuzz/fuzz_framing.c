// libFuzzer target: the port's framing, read as the renderer reads stdin.
// proto_read must turn any byte stream into whole messages or an error:
// never read past a frame, never trust a length, never leak.

#define _GNU_SOURCE // memfd_create(2), pwrite(2)

#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../renderer/core/protocol.h"

static int input_fd;

int LLVMFuzzerInitialize(int *, char ***) {
    input_fd = memfd_create("fuzz-input", MFD_CLOEXEC);
    if (input_fd < 0)
        abort();
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (ftruncate(input_fd, 0) < 0 || pwrite(input_fd, data, size, 0) != (ssize_t)size ||
        lseek(input_fd, 0, SEEK_SET) < 0)
        abort();
    uint8_t *msg;
    uint32_t len;
    while (proto_read(input_fd, &msg, &len) == READ_OK) {
        if (len == 0 || len > max_message_size)
            abort();
        // Touch every byte: ASan reports any that isn't the message's.
        volatile uint8_t sum = 0;
        for (uint32_t i = 0; i < len; i++)
            sum ^= msg[i];
        free(msg);
    }
    return 0;
}
