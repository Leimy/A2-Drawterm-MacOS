/* Test a separately obtained FAAD2 library against finite ADTS fixtures.
   This is an evaluation tool, not an A2 playback backend. */
#include <neaacdec.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int result = 1;
    FILE *input = fopen(argv[1], "rb"), *output = fopen(argv[2], "wb");
    unsigned char *data = NULL;
    NeAACDecHandle decoder = NULL;
    if (!input || !output) goto done;
    if (fseek(input, 0, SEEK_END)) goto done;
    long size = ftell(input);
    if (size <= 0 || size > 1048576 || fseek(input, 0, SEEK_SET)) goto done;
    data = calloc(1, (size_t)size + 32);
    if (!data || fread(data, 1, size, input) != (size_t)size) goto done;
    decoder = NeAACDecOpen();
    if (!decoder) goto done;
    NeAACDecConfigurationPtr config = NeAACDecGetCurrentConfiguration(decoder);
    config->outputFormat = FAAD_FMT_16BIT;
    config->downMatrix = 1;
    if (!NeAACDecSetConfiguration(decoder, config)) goto done;
    unsigned long rate = 0, samples = 0;
    unsigned char channels = 0;
    unsigned frames = 0;
    long consumed = NeAACDecInit(decoder, data, size, &rate, &channels);
    if (consumed < 0 || consumed > size) goto done;
    while (consumed + 7 <= size) {
        const unsigned char *header = data + consumed;
        if (header[0] != 255 || (header[1] & 0xf6) != 0xf0) goto done;
        unsigned length = ((header[3] & 3) << 11) | (header[4] << 3) | (header[5] >> 5);
        if (length < 7 || length > (unsigned long)(size - consumed)) goto done;
        NeAACDecFrameInfo info = {0};
        void *pcm = NeAACDecDecode(decoder, &info, data + consumed, length);
        if (info.error) {
            fprintf(stderr, "decode frame %u: %s\n", frames, NeAACDecGetErrorMessage(info.error));
            goto done;
        }
        if (info.samples) {
            if (!pcm || info.channels < 1 || info.channels > 2 ||
                fwrite(pcm, 2, info.samples, output) != info.samples) goto done;
            rate = info.samplerate; channels = info.channels; samples += info.samples;
        }
        consumed += length; frames++;
    }
    if (consumed != size) goto done;
    printf("frames=%u samples=%lu rate=%lu channels=%u\n", frames, samples, rate, channels);
    result = 0;
done:
    if (decoder) NeAACDecClose(decoder);
    free(data);
    if (input) fclose(input);
    if (output && fclose(output)) result = 1;
    return result;
}
