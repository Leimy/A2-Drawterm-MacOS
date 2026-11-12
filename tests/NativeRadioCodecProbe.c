/* Exercise the public codec bridge with fragmented input under sanitizers.
   Build with DarwinCodecs.c and AudioToolbox; pass the packaged data directory. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

void *a2codec_create(void);
void a2codec_destroy(void *);
int a2codec_feed(void *, const void *, int);
void a2codec_end(void *);
int a2codec_read(void *, void *, int);
int a2codec_error(void *);

static int check(const char *directory, const char *name, int chunk, uint64_t expected) {
    char path[4096];
    if (snprintf(path, sizeof path, "%s/%s", directory, name) >= (int)sizeof path) return 1;
    FILE *file = fopen(path, "rb");
    if (!file) return 1;
    void *decoder = a2codec_create();
    if (!decoder) { fclose(file); return 1; }
    unsigned char input[4096];
    int16_t output[2048];
    uint64_t bytes = 0;
    int ended = 0, failed = 0;
    for (;;) {
        int n = a2codec_read(decoder, output, sizeof output);
        if (n > 0) { bytes += n; continue; }
        if (n == -1) break;
        if (n < 0 || ended) { failed = 1; break; }
        size_t count = fread(input, 1, chunk, file);
        if (count && a2codec_feed(decoder, input, (int)count)) { failed = 1; break; }
        if (!count) { a2codec_end(decoder); ended = 1; }
    }
    if (failed || (expected && bytes != expected)) {
        fprintf(stderr, "FAIL %s chunk=%d bytes=%llu expected=%llu error=%d\n", name, chunk,
                (unsigned long long)bytes, (unsigned long long)expected, a2codec_error(decoder));
        failed = 1;
    }
    a2codec_destroy(decoder);
    fclose(file);
    return failed;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const char *names[] = {"RadioGlobeTest.mp3", "RadioGlobeTest.aac", "RadioGlobeTest-HE.aac",
        "RadioGlobeTest-Mono.aac", "RadioGlobeTest.ogg", "RadioGlobeTest.flac",
        "RadioGlobeTest.opus", "RadioGlobeTest-FLAC.ogg"};
    const int chunks[] = {1, 7, 137, 4096};
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
        for (unsigned j = 0; j < sizeof chunks / sizeof chunks[0]; j++)
            if (check(argv[1], names[i], chunks[j], i >= 4 ? 352800 : 0)) return 1;
        printf("BOUNDARIES PASS %s (1/7/137/4096-byte input)\n", names[i]);
    }
    return 0;
}
