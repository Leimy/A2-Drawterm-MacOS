/* Execute one entry in a trusted, self-contained Fox raw-link test fixture.
 * Usage: probe binary entry-offset expected-result [absolute-relocation-offset ...]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>

int main(int argc, char **argv)
{
    if (argc < 4) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END)) return 2;
    long size = ftell(file);
    if (size <= 0) return 2;
    rewind(file);
    size_t length = (size_t)size, page = (size_t)getpagesize();
    size_t allocation = (length + page - 1) & ~(page - 1);
    size_t entry = strtoull(argv[2], NULL, 0);
    if (entry >= length || entry % 4) return 2;
    unsigned char *code = mmap(NULL, allocation, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
    if (code == MAP_FAILED || fread(code, 1, length, file) != length) return 2;
    fclose(file);
    for (int i = 4; i < argc; ++i) {
        size_t offset = strtoull(argv[i], NULL, 0);
        if (offset > length || length - offset < sizeof(uint64_t)) return 2;
        uint64_t address;
        memcpy(&address, code + offset, sizeof(address));
        address += (uintptr_t)code;
        memcpy(code + offset, &address, sizeof(address));
    }
    sys_icache_invalidate(code, length);
    if (mprotect(code, allocation, PROT_READ | PROT_EXEC)) return 2;
    uint64_t actual = ((uint64_t (*)(void))(code + entry))();
    printf("returned %llu (0x%llx)\n", (unsigned long long)actual,
           (unsigned long long)actual);
    munmap(code, allocation);
    return actual != strtoull(argv[3], NULL, 0);
}
