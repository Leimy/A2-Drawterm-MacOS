/* Incremental system audio decoding. All parser/converter callbacks stay in C. */
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
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
    unsigned char probe[65536];
    unsigned probe_used;
    unsigned char partial[65536];
    unsigned partial_size, page_segment, page_offset, page_active;
    unsigned ogg_started, ogg_serial, ogg_sequence, ogg_headers, opus_preskip, opus_drop;
    uint64_t opus_limit, opus_output;
    double opus_gain;
    unsigned ogg_audio, ogg_live_page, ogg_page_frames;
    uint64_t ogg_base;
    unsigned flac_stage, flac_scan, flac_crc, flac_rate;
    uint64_t flac_limit, flac_output;
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

static void properties(void *, AudioFileStreamID, AudioFileStreamPropertyID, UInt32 *);
static void packets(void *, UInt32, UInt32, const void *, AudioStreamPacketDescription *);

static int flac_info(Decoder *d, const unsigned char *p, unsigned n) {
    if (n < 42 || memcmp(p, "fLaC", 4) || (p[4] & 127) || p[5] || p[6] || p[7] != 34) return 0;
    uint64_t samples = (uint64_t)(p[21] & 15) << 32 | (uint64_t)p[22] << 24 |
                       (uint64_t)p[23] << 16 | (uint64_t)p[24] << 8 | p[25];
    unsigned rate = (unsigned)p[18] << 12 | (unsigned)p[19] << 4 | p[20] >> 4;
    if (!rate) return 0;
    unsigned channels = ((p[20] >> 1) & 7) + 1;
    unsigned bits = (((p[20] & 1) << 4) | p[21] >> 4) + 1;
    if (channels > 2 || rate < 8000 || rate > 192000 || bits > 32) return 0;
    d->flac_rate = rate;
    d->format.mFormatID = kAudioFormatFLAC; d->format.mSampleRate = rate;
    d->format.mChannelsPerFrame = channels;
    d->format.mFramesPerPacket = (unsigned)p[10] << 8 | p[11];
    d->format.mFormatFlags = bits <= 16 ? 1 : bits <= 20 ? 2 : bits <= 24 ? 3 : 4;
    d->error = make_converter(d);
    d->flac_limit = samples / rate * 44100 + samples % rate * 44100 / rate;
    return 1;
}

static unsigned flac_frames(const unsigned char *p, unsigned n) {
    if (n < 7 || p[0] != 255 || (p[1] & 254) != 248) return 0;
    unsigned code = p[2] >> 4;
    if (code == 1) return 192;
    if (code >= 2 && code <= 5) return 576u << (code - 2);
    if (code >= 8) return 256u << (code - 8);
    unsigned utf = p[4] < 128 ? 1 : p[4] < 224 ? 2 : p[4] < 240 ? 3 :
                   p[4] < 248 ? 4 : p[4] < 252 ? 5 : p[4] < 254 ? 6 : 7;
    unsigned offset = 4 + utf;
    if (offset + 2 >= n) return 0;
    if (code == 6) return p[offset] + 1;
    if (code == 7) return ((unsigned)p[offset] << 8 | p[offset + 1]) + 1;
    return 0;
}

static unsigned flac_header_size(const unsigned char *p, unsigned n) {
    if (n < 6 || p[0] != 255 || (p[1] & 254) != 248 || !(p[2] >> 4) ||
        (p[2] & 15) == 15 || (p[3] >> 4) > 10 || (p[3] & 1) || p[4] == 255) return 0;
    unsigned utf = p[4] < 128 ? 1 : p[4] < 224 ? 2 : p[4] < 240 ? 3 :
                   p[4] < 248 ? 4 : p[4] < 252 ? 5 : p[4] < 254 ? 6 : 7;
    if (n < 4 + utf) return 0;
    for (unsigned i = 1; i < utf; i++) if ((p[4 + i] & 192) != 128) return 0;
    unsigned block = p[2] >> 4, rate = p[2] & 15;
    unsigned length = 5 + utf + (block == 6 ? 1 : block == 7 ? 2 : 0) +
                      (rate == 12 ? 1 : rate >= 13 ? 2 : 0);
    if (n < length) return 0;
    unsigned crc = 0;
    for (unsigned i = 0; i < length; i++) {
        crc ^= p[i];
        for (unsigned j = 0; j < 8; j++) crc = ((crc << 1) ^ ((crc & 128) ? 7 : 0)) & 255;
    }
    return crc ? 0 : length;
}

static unsigned flac_crc_byte(unsigned crc, unsigned char byte) {
    crc ^= (unsigned)byte << 8;
    for (unsigned j = 0; j < 8; j++) crc = ((crc << 1) ^ ((crc & 32768) ? 0x8005 : 0)) & 65535;
    return crc;
}

static void queue_flac(Decoder *d, const unsigned char *data, unsigned size) {
    unsigned frames = flac_header_size(data, size) ? flac_frames(data, size) : 0, crc = 0;
    for (unsigned i = 0; i < size; i++) crc = flac_crc_byte(crc, data[i]);
    if (!frames || crc || d->count == PacketSlots || size > ByteLimit - d->bytes) { d->error = -2204; return; }
    Packet *p = malloc(sizeof *p + size);
    if (!p) { d->error = -1; return; }
    p->size = size; p->frames = frames; memcpy(p->bytes, data, size);
    d->packets[(d->head + d->count) % PacketSlots] = p;
    d->count++; d->bytes += size; d->queued_frames += frames;
}

/* The native FLAC framing layer verifies header CRC8 and frame CRC16 itself.
   AudioToolbox receives complete packets only, bypassing its incremental FLAC
   file parser (which overran an internal buffer in fragmented-input tests). */
static void flac_packets(Decoder *d, unsigned target) {
    if (!d->flac_stage) {
        if (d->used < 4) return;
        discard(d, 4); d->flac_stage = 1;
    }
    while (d->flac_stage == 1 && !d->error) {
        if (d->used < 4) return;
        unsigned char *p = d->compressed;
        unsigned size = 4 + ((unsigned)p[1] << 16 | (unsigned)p[2] << 8 | p[3]);
        if (size > ByteLimit) { d->error = -2205; return; }
        if (d->used < size) return;
        int last = p[0] & 128;
        discard(d, size);
        if (last) d->flac_stage = 2;
    }
    while (!d->error && d->queued_frames < target && d->used) {
        if (d->used < 16 && !d->eof) return;
        if (!flac_header_size(d->compressed, d->used)) { d->error = -2206; return; }
        for (;;) {
            unsigned offset = d->flac_scan;
            if (offset >= 8 && !d->flac_crc &&
                ((offset < d->used && flac_header_size(d->compressed + offset, d->used - offset)) ||
                 (offset == d->used && d->eof))) {
                queue_flac(d, d->compressed, offset); discard(d, offset);
                d->flac_scan = d->flac_crc = 0;
                break;
            }
            /* Retain a possible next header across input boundaries. */
            if (offset >= 8 && !d->flac_crc && d->used - offset < 16 && !d->eof) return;
            if (offset == d->used) { if (d->eof) d->error = -2207; return; }
            d->flac_crc = flac_crc_byte(d->flac_crc, d->compressed[d->flac_scan++]);
        }
    }
}

static unsigned little32(const unsigned char *p) {
    return (unsigned)p[0] | (unsigned)p[1] << 8 | (unsigned)p[2] << 16 | (unsigned)p[3] << 24;
}
static unsigned opus_frames(const unsigned char *p, unsigned size) {
    if (!size) return 0;
    unsigned config = p[0] >> 3, frames = p[0] & 3;
    unsigned samples = config >= 16 ? 120u << (config & 3) :
                       config >= 12 ? 480u << (config & 1) :
                       (config & 3) == 3 ? 2880 : 480u << (config & 3);
    frames = !frames ? 1 : frames == 3 ? (size >= 2 ? p[1] & 63 : 0) : 2;
    return frames && frames * samples <= 5760 ? frames * samples : 0;
}

/* Ogg framing is independent of the system file parser, which does not expose
   incremental Ogg Opus/FLAC parsing. Opus accepts mono/stereo mapping family zero.
   Keep pages, continued packets and queued audio bounded, and check page CRCs. */
static void ogg_packets(Decoder *d, unsigned target) {
    while (!d->error && !d->chain && (d->queued_frames < target || !d->converter)) {
        if (d->used < 27) return;
        unsigned char *p = d->compressed;
        if (memcmp(p, "OggS", 4) || p[4]) { d->error = -2100; return; }
        unsigned segments = p[26], header = 27 + segments, size = header;
        if (d->used < header) return;
        for (unsigned i = 0; i < segments; i++) size += p[27 + i];
        if (d->used < size) return;
        if (!d->page_active) {
            if ((p[5] & 2) && d->converter) { d->chain = 1; return; }
            unsigned crc = 0;
            for (unsigned i = 0; i < size; i++) {
                crc ^= (i >= 22 && i < 26 ? 0 : (unsigned)p[i]) << 24;
                for (unsigned j = 0; j < 8; j++) crc = (crc << 1) ^ ((crc & 0x80000000u) ? 0x04c11db7u : 0);
            }
            unsigned serial = little32(p + 14), sequence = little32(p + 18);
            if (crc != little32(p + 22) ||
                (d->ogg_started && (serial != d->ogg_serial ||
                 (sequence != d->ogg_sequence && (d->ogg_audio || d->ogg_headers != 2)))) ||
                (!d->ogg_started && (!(p[5] & 2) || sequence)) ||
                (!!(p[5] & 1) != !!d->partial_size)) { d->error = -2101; return; }
            d->ogg_live_page = d->ogg_started && sequence != d->ogg_sequence;
            d->ogg_page_frames = 0;
            d->ogg_started = 1; d->ogg_serial = serial; d->ogg_sequence = sequence + 1;
            d->page_segment = 0; d->page_offset = header; d->page_active = 1;
            if (p[5] & 4) {
                uint64_t granule = (uint64_t)little32(p + 6) | (uint64_t)little32(p + 10) << 32;
                if (granule > INT64_MAX || granule < d->opus_preskip + d->ogg_base) { d->error = -2102; return; }
                granule -= d->opus_preskip + d->ogg_base;
                if (d->mode == 3) d->opus_limit = granule / 48000 * 44100 + granule % 48000 * 44100 / 48000;
                else if (d->flac_rate) d->flac_limit = granule / d->flac_rate * 44100 + granule % d->flac_rate * 44100 / d->flac_rate;
            }
        }
        while (d->page_segment < segments) {
            unsigned n = p[27 + d->page_segment++];
            if (n > sizeof d->partial - d->partial_size) { d->error = -2103; return; }
            memcpy(d->partial + d->partial_size, p + d->page_offset, n);
            d->partial_size += n; d->page_offset += n;
            if (n == 255) continue;
            unsigned length = d->partial_size; unsigned char *packet = d->partial;
            d->partial_size = 0;
            if (d->mode == 4) {
                const unsigned char *native = packet;
                if (!d->ogg_headers) {
                    if (length != 51 || memcmp(packet, "\177FLAC\1", 6) || packet[6] ||
                        !flac_info(d, packet + 9, length - 9)) { d->error = -2201; return; }
                    d->ogg_headers = 1; native += 9;
                } else if (d->ogg_headers == 1) {
                    if (length < 4 || (packet[0] & 127) == 127 ||
                        (((unsigned)packet[1] << 16 | (unsigned)packet[2] << 8 | packet[3]) != length - 4)) {
                        d->error = -2202; return;
                    }
                } else {
                    unsigned frames = flac_frames(packet, length);
                    if (!frames) { d->error = -2203; return; }
                    d->ogg_audio = 1; d->ogg_page_frames += frames;
                    queue_flac(d, packet, length);
                }
                if (d->ogg_headers == 1 && (native[0] & 128)) d->ogg_headers = 2;

            } else if (!d->ogg_headers) {
                if (length != 19 || memcmp(packet, "OpusHead", 8) || packet[8] != 1 ||
                    packet[9] < 1 || packet[9] > 2 || packet[18]) { d->error = -2104; return; }
                d->opus_preskip = packet[10] | packet[11] << 8;
                d->opus_drop = (d->opus_preskip * 44100u + 24000) / 48000;
                int gain = (int16_t)(packet[16] | packet[17] << 8);
                d->opus_gain = pow(10.0, gain / (256.0 * 20));
                d->format.mFormatID = kAudioFormatOpus; d->format.mSampleRate = 48000;
                d->format.mChannelsPerFrame = packet[9];
                d->error = make_converter(d);
                /* Apply pre-skip/gain here after sample-rate conversion. */
                unsigned char cookie[19]; memcpy(cookie, packet, 19);
                cookie[10] = cookie[11] = cookie[16] = cookie[17] = 0;
                if (!d->error) d->error = AudioConverterSetProperty(d->converter,
                    kAudioConverterDecompressionMagicCookie, sizeof cookie, cookie);
                d->ogg_headers = 1;
            } else if (d->ogg_headers == 1) {
                if (length < 16 || memcmp(packet, "OpusTags", 8)) { d->error = -2105; return; }
                d->ogg_headers = 2;
            } else {
                unsigned frames = opus_frames(packet, length);
                if (!frames || d->count == PacketSlots || length > ByteLimit - d->bytes) { d->error = -2106; return; }
                Packet *q = malloc(sizeof *q + length);
                if (!q) { d->error = -1; return; }
                d->ogg_audio = 1; d->ogg_page_frames += frames;
                q->size = length; q->frames = frames; memcpy(q->bytes, packet, length);
                d->packets[(d->head + d->count) % PacketSlots] = q;
                d->count++; d->bytes += length; d->queued_frames += frames;
            }
            if (d->error || d->queued_frames >= target) return;
        }
        if (d->ogg_live_page) {
            uint64_t granule = (uint64_t)little32(p + 6) | (uint64_t)little32(p + 10) << 32;
            if (granule > d->ogg_page_frames) d->ogg_base = granule - d->ogg_page_frames;
        }
        discard(d, size); d->page_active = 0;
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
        if (d->format.mFormatID == kAudioFormatFLAC) p->frames = flac_frames((const unsigned char *)data + offset, size);
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
    d->opus_limit = UINT64_MAX;
    /* Open only after sniffing: Icecast may attach in the middle of a frame. */
    return d;
}

/* Validate two adjacent MPEG/ADTS headers before dropping an arbitrary live
   prefix. A sync-like word inside compressed audio is not sufficient. */
static unsigned frame_size(const unsigned char *p, unsigned n, AudioFileTypeID *type) {
    if (n < 7 || p[0] != 0xff) return 0;
    if ((p[1] & 0xf6) == 0xf0) {
        unsigned size = ((p[3] & 3) << 11) | (p[4] << 3) | (p[5] >> 5);
        if ((p[2] & 0x3c) == 0x3c || size < 7) return 0;
        *type = kAudioFileAAC_ADTSType; return size;
    }
    if ((p[1] & 0xe0) != 0xe0) return 0;
    unsigned version = (p[1] >> 3) & 3, layer = (p[1] >> 1) & 3;
    unsigned br = p[2] >> 4, sr = (p[2] >> 2) & 3;
    if (version == 1 || layer < 1 || layer > 2 || !br || br == 15 || sr == 3) return 0;
    static const unsigned rates[3] = {44100, 48000, 32000};
    static const unsigned mpeg1[2][14] = {
        {32,40,48,56,64,80,96,112,128,160,192,224,256,320},
        {32,48,56,64,80,96,112,128,160,192,224,256,320,384}};
    static const unsigned mpeg2[14] = {8,16,24,32,40,48,56,64,80,96,112,128,144,160};
    unsigned rate = rates[sr] >> (version == 3 ? 0 : version == 2 ? 1 : 2);
    unsigned bitrate = version == 3 ? mpeg1[layer - 1][br - 1] : mpeg2[br - 1];
    *type = layer == 1 ? kAudioFileMP3Type : kAudioFileMP2Type;
    return (layer == 1 && version != 3 ? 72 : 144) * bitrate * 1000 / rate + ((p[2] >> 1) & 1);
}

static int identify(Decoder *d) {
    const unsigned char *p = d->probe; unsigned n = d->probe_used, skip = 0;
    AudioFileTypeID type = 0;
    if (n < 64) return 0;
    if (!memcmp(p, "OggS", 4)) {
        unsigned start = 27 + p[26];
        if (n < start + 8) return 0;
        if (!memcmp(p + start, "\1vorbis", 7)) d->mode = 2;
        else if (!memcmp(p + start, "OpusHead", 8)) d->mode = 3;
        else if (!memcmp(p + start, "\177FLAC", 5)) d->mode = 4;
        else { d->error = -2107; return -1; }
        type = 'Oggf';
    } else if (!memcmp(p, "fLaC", 4)) {
        d->mode = 5; type = kAudioFileFLACType;
        if (!flac_info(d, p, n)) { d->error = -2200; return -1; }
    }
    else if (!memcmp(p, "ID3", 3)) { d->mode = 1; type = kAudioFileMP3Type; }
    else {
        for (unsigned i = 0; i + 7 < n; i++) {
            AudioFileTypeID next = 0;
            unsigned size = frame_size(p + i, n - i, &type);
            if (size && size + 7 <= n - i && frame_size(p + i + size, n - i - size, &next) && type == next) {
                skip = i; d->mode = 1; break;
            }
        }
        if (!d->mode) return 0;
    }
    if (skip) { memmove(d->probe, d->probe + skip, n - skip); d->probe_used -= skip; }
    if (d->mode == 1) d->error = AudioFileStreamOpen(d, properties, packets, type, &d->stream);
    return d->error ? -1 : 1;
}

int a2codec_feed(void *context, const void *data, int length) {
    Decoder *d = context;
    if (!d || !data || length < 0 || length > 4096 || d->eof) return -1;
    if (d->error) return d->error;
    if (!d->mode) {
        if ((unsigned)length > sizeof d->probe - d->probe_used) return d->error = -2010;
        memcpy(d->probe + d->probe_used, data, length); d->probe_used += length;
        int found = identify(d);
        if (found < 0) return d->error;
        if (!found) return d->probe_used == sizeof d->probe ? (d->error = -2010) : 0;
        data = d->probe; length = d->probe_used;
    }
    if (d->mode >= 2) {
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
        if (d->mode == 2) open_vorbis(d);
        else if (d->mode == 5) flac_packets(d, 1);
        else if (!d->converter) ogg_packets(d, 1);
        return d->error;
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
    if (d->mode == 3 || d->mode == 4) ogg_packets(d, target);
    if (d->mode == 5) flac_packets(d, target);
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
        if (d->vorbis) stb_vorbis_close(d->vorbis); d->vorbis = NULL;
        free(d->current); d->current = NULL; d->current_offset = 0;
        d->chain = 0; memset(&d->format, 0, sizeof d->format);
        if (d->mode == 2) open_vorbis(d);
        else {
            d->ogg_headers = d->ogg_started = d->opus_drop = d->ogg_audio = 0;
            d->ogg_base = 0;
            if (d->mode == 4) {
                d->flac_stage = d->flac_scan = d->flac_crc = 0;
                d->flac_limit = d->flac_output = 0;
            }
            d->opus_output = 0; d->opus_limit = UINT64_MAX;
            ogg_packets(d, target);
        }
        if (d->converter) goto retry;
        return d->eof ? -2 : 0;
    }
    if (!frames && d->eof) return -1;
    if (d->mode == 3 && frames) {
        unsigned drop = frames < d->opus_drop ? frames : d->opus_drop;
        d->opus_drop -= drop; frames -= drop;
        memmove(pcm, (char *)pcm + drop * 4, frames * 4);
        if (d->opus_output >= d->opus_limit) frames = 0;
        else if (frames > d->opus_limit - d->opus_output) frames = (UInt32)(d->opus_limit - d->opus_output);
        d->opus_output += frames;
        int16_t *samples = pcm;
        for (unsigned i = 0; i < frames * 2; i++) {
            double value = samples[i] * d->opus_gain;
            samples[i] = value > 32767 ? 32767 : value < -32768 ? -32768 : (int16_t)value;
        }
        if (!frames) goto retry;
    }
    if (d->format.mFormatID == kAudioFormatFLAC && d->flac_limit) {
        if (d->flac_output >= d->flac_limit) { if (d->mode == 4) goto retry; return -1; }
        if (frames > d->flac_limit - d->flac_output) frames = (UInt32)(d->flac_limit - d->flac_output);
        d->flac_output += frames;
    }
    return frames * 4;
}

int a2codec_error(void *context) { return ((Decoder *)context)->error; }
