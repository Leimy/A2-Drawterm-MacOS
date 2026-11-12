/* Incremental system audio decoding. All parser/converter callbacks stay in C. */
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PULLDATA_API
#define STB_VORBIS_NO_INTEGER_CONVERSION
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "../../third_party/stb_vorbis.c"
#pragma clang diagnostic pop

enum { PacketSlots = 256, ByteLimit = 1048576, NeedInput = 0x77616974 };
typedef struct Packet {
    UInt32 size, frames;
    unsigned char bytes[];
} Packet;
typedef struct {
    AudioFileStreamID stream;
    AudioConverterRef converter;
    AudioStreamBasicDescription format;
    Packet *packets[PacketSlots], *current;
    AudioStreamPacketDescription description;
    unsigned head, count, bytes;
    unsigned queued_frames, current_offset;
    int eof, mode, pcm, chain;
    stb_vorbis *vorbis;
    char *vorbis_memory;
    unsigned char *compressed;
    unsigned used, allocated;
    OSStatus error;
} Decoder;

static OSStatus make_converter(Decoder *d) {
    AudioStreamBasicDescription output = {0};
    output.mSampleRate = 44100; output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    output.mBytesPerPacket = output.mBytesPerFrame = 4; output.mFramesPerPacket = 1;
    output.mChannelsPerFrame = 2; output.mBitsPerChannel = 16;
    OSStatus status = AudioConverterNew(&d->format, &output, &d->converter);
    if (!status && d->format.mChannelsPerFrame == 1) {
        SInt32 map[2] = {0, 0};
        status = AudioConverterSetProperty(d->converter, kAudioConverterChannelMap, sizeof map, map);
    }
    return status;
}

static void discard(Decoder *d, unsigned n) {
    memmove(d->compressed, d->compressed + n, d->used - n); d->used -= n;
}

static void open_vorbis(Decoder *d) {
    if (d->vorbis || d->error) return;
    int consumed = 0, error = 0;
    if (!d->vorbis_memory) d->vorbis_memory = malloc(8 * ByteLimit);
    if (!d->vorbis_memory) { d->error = -1; return; }
    stb_vorbis_alloc arena = {d->vorbis_memory, 8 * ByteLimit};
    d->vorbis = stb_vorbis_open_pushdata(d->compressed, d->used, &consumed, &error, &arena);
    if (!d->vorbis) { if (error != VORBIS_need_more_data) d->error = -2001; return; }
    discard(d, consumed);
    stb_vorbis_info info = stb_vorbis_get_info(d->vorbis);
    if (info.channels < 1 || info.channels > 2 || info.sample_rate < 8000 || info.sample_rate > 192000) { d->error = -2002; return; }
    d->pcm = 1;
    d->format.mSampleRate = info.sample_rate; d->format.mFormatID = kAudioFormatLinearPCM;
    d->format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    d->format.mBytesPerPacket = d->format.mBytesPerFrame = info.channels * sizeof(float);
    d->format.mFramesPerPacket = 1; d->format.mChannelsPerFrame = info.channels; d->format.mBitsPerChannel = 32;
    d->error = make_converter(d);
}

static void vorbis_packets(Decoder *d, unsigned target) {
    while (d->queued_frames < target && !d->error && !d->chain && d->used) {
        /* A new logical Vorbis stream may change codebooks or sample rate. */
        if (d->used >= 6 && !memcmp(d->compressed, "OggS", 4) && (d->compressed[5] & 2)) {
            d->chain = 1; return;
        }
        int channels = 0, frames = 0; float **output = NULL;
        int consumed = stb_vorbis_decode_frame_pushdata(d->vorbis, d->compressed, d->used, &channels, &output, &frames);
        if (consumed < 0 || (unsigned)consumed > d->used) { d->error = -2003; return; }
        if (!consumed) return;
        discard(d, consumed);
        if (!frames) continue;
        if (channels != (int)d->format.mChannelsPerFrame || frames > 8192) { d->error = -2004; return; }
        unsigned size = frames * channels * sizeof(float);
        if (size > ByteLimit - d->bytes || d->count == PacketSlots) { d->error = -2005; return; }
        Packet *p = malloc(sizeof *p + size);
        if (!p) { d->error = -1; return; }
        p->size = size; p->frames = frames;
        float *pcm = (float *)p->bytes;
        for (int i = 0; i < frames; i++) for (int c = 0; c < channels; c++) pcm[i * channels + c] = output[c][i];
        d->packets[(d->head + d->count) % PacketSlots] = p;
        d->count++; d->bytes += size; d->queued_frames += frames;
    }
}

static void properties(void *context, AudioFileStreamID stream, AudioFileStreamPropertyID property, UInt32 *flags) {
    (void)flags;
    Decoder *d = context;
    if (property != kAudioFileStreamProperty_ReadyToProducePackets || d->converter || d->error) return;
    UInt32 size = sizeof d->format;
    d->error = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &d->format);
    if (d->error) return;
    AudioFormatListItem formats[32]; size = sizeof formats;
    if (!AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &size, formats)) {
        for (unsigned i = 0; i < size / sizeof formats[0]; i++) {
            AudioFormatID id = formats[i].mASBD.mFormatID;
            if (id == kAudioFormatMPEG4AAC_HE || id == kAudioFormatMPEG4AAC_HE_V2) d->format = formats[i].mASBD;
        }
    }
    d->error = make_converter(d);
    if (d->error) return;
    Boolean writable;
    if (!AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &size, &writable) && size) {
        if (size > ByteLimit) { d->error = -1; return; }
        void *cookie = malloc(size);
        if (!cookie) { d->error = -1; return; }
        d->error = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &size, cookie);
        if (!d->error) d->error = AudioConverterSetProperty(d->converter, kAudioConverterDecompressionMagicCookie, size, cookie);
        free(cookie);
    }
}

static void packets(void *context, UInt32 bytes, UInt32 count, const void *data, AudioStreamPacketDescription *descriptions) {
    Decoder *d = context;
    if (d->error) return;
    for (UInt32 i = 0; i < count; i++) {
        UInt32 size = descriptions ? descriptions[i].mDataByteSize : d->format.mBytesPerPacket;
        SInt64 offset = descriptions ? descriptions[i].mStartOffset : (SInt64)i * size;
        if (!size || offset < 0 || offset > bytes || size > bytes - offset ||
            size > ByteLimit - d->bytes || d->count == PacketSlots) { d->error = -1; return; }
        Packet *p = malloc(sizeof *p + size);
        if (!p) { d->error = -1; return; }
        p->size = size; p->frames = descriptions ? descriptions[i].mVariableFramesInPacket : 0;
        if (!p->frames) p->frames = d->format.mFramesPerPacket ? d->format.mFramesPerPacket : 1024;
        memcpy(p->bytes, (const char *)data + offset, size);
        d->packets[(d->head + d->count) % PacketSlots] = p; d->count++; d->bytes += size; d->queued_frames += p->frames;
    }
}

static OSStatus input(AudioConverterRef converter, UInt32 *count, AudioBufferList *buffers,
                      AudioStreamPacketDescription **descriptions, void *context) {
    (void)converter;
    Decoder *d = context;
    if (d->current && (!d->pcm || d->current_offset == d->current->frames)) { free(d->current); d->current = NULL; }
    if (!d->current) {
        if (!d->count) { *count = 0; return d->eof || d->chain ? noErr : NeedInput; }
        d->current = d->packets[d->head]; d->head = (d->head + 1) % PacketSlots;
        d->count--; d->bytes -= d->current->size; d->current_offset = 0;
    }
    Packet *p = d->current;
    buffers->mNumberBuffers = 1;
    buffers->mBuffers[0].mNumberChannels = d->format.mChannelsPerFrame;
    if (d->pcm) {
        UInt32 n = *count;
        if (n > p->frames - d->current_offset) n = p->frames - d->current_offset;
        buffers->mBuffers[0].mData = p->bytes + d->current_offset * d->format.mBytesPerFrame;
        buffers->mBuffers[0].mDataByteSize = n * d->format.mBytesPerFrame;
        d->current_offset += n; d->queued_frames -= n; *count = n;
        if (descriptions) *descriptions = NULL;
        return noErr;
    }
    *count = 1; d->queued_frames -= p->frames;
    buffers->mBuffers[0].mData = p->bytes; buffers->mBuffers[0].mDataByteSize = p->size;
    d->description.mStartOffset = 0; d->description.mDataByteSize = p->size;
    d->description.mVariableFramesInPacket = p->frames;
    if (descriptions) *descriptions = &d->description;
    return noErr;
}

void a2codec_destroy(void *context) {
    Decoder *d = context;
    if (!d) return;
    if (d->converter) AudioConverterDispose(d->converter);
    if (d->stream) AudioFileStreamClose(d->stream);
    if (d->vorbis) stb_vorbis_close(d->vorbis);
    free(d->vorbis_memory);
    free(d->compressed);
    free(d->current);
    while (d->count) { free(d->packets[d->head]); d->head = (d->head + 1) % PacketSlots; d->count--; }
    free(d);
}

void *a2codec_create(void) {
    Decoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    if (AudioFileStreamOpen(d, properties, packets, 0, &d->stream)) { free(d); return NULL; }
    return d;
}

int a2codec_feed(void *context, const void *data, int length) {
    Decoder *d = context;
    if (!d || !data || length < 0 || length > 4096 || d->eof) return -1;
    if (d->error) return d->error;
    if (!d->mode) d->mode = length >= 4 && !memcmp(data, "OggS", 4) ? 2 : 1;
    if (d->mode == 2) {
        if ((unsigned)length > ByteLimit - d->used) return d->error = -2006;
        if (d->used + length > d->allocated) {
            unsigned capacity = d->allocated ? d->allocated * 2 : 8192;
            if (capacity < d->used + length) capacity = d->used + length;
            if (capacity > ByteLimit) capacity = ByteLimit;
            void *buffer = realloc(d->compressed, capacity);
            if (!buffer) return d->error = -1;
            d->compressed = buffer; d->allocated = capacity;
        }
        memcpy(d->compressed + d->used, data, length); d->used += length;
        open_vorbis(d); return d->error;
    }
    OSStatus status = AudioFileStreamParseBytes(d->stream, length, data, 0);
    if (status) d->error = status;
    return d->error;
}

int a2codec_ready(void *context) {
    Decoder *d = context;
    return d && d->converter && !d->error;
}

void a2codec_end(void *context) { ((Decoder *)context)->eof = 1; }

/* Returns PCM byte count, zero for more compressed input, -1 for EOF, -2 for error. */
int a2codec_read(void *context, void *pcm, int capacity) {
    Decoder *d = context;
retry:
    if (!d || !pcm || capacity < 4 || capacity > 4096 || d->error) return -2;
    if (!d->converter) return d->eof ? -2 : 0;
    unsigned target = d->pcm ? (unsigned)((capacity / 4) * d->format.mSampleRate / 44100) + 1024 : 16384;
    if (d->mode == 2) vorbis_packets(d, target);
    if (d->error) return -2;
    if (!d->eof && !d->chain && d->queued_frames < target) return 0;
    AudioBufferList output = {0};
    output.mNumberBuffers = 1; output.mBuffers[0].mNumberChannels = 2;
    output.mBuffers[0].mData = pcm; output.mBuffers[0].mDataByteSize = capacity;
    UInt32 frames = capacity / 4;
    OSStatus status = AudioConverterFillComplexBuffer(d->converter, input, d, &frames, &output, NULL);
    if (status == NeedInput) return 0;
    if (status) { d->error = status; return -2; }
    if (!frames && d->chain) {
        AudioConverterDispose(d->converter); d->converter = NULL;
        stb_vorbis_close(d->vorbis); d->vorbis = NULL;
        free(d->current); d->current = NULL; d->current_offset = 0;
        d->chain = 0; memset(&d->format, 0, sizeof d->format);
        open_vorbis(d);
        if (d->converter) goto retry;
        return d->eof ? -2 : 0;
    }
    if (!frames && d->eof) return -1;
    return frames * 4;
}

int a2codec_error(void *context) { return ((Decoder *)context)->error; }
