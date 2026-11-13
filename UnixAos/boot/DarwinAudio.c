/* Native PCM output. AudioQueue callbacks stay in C; no foreign thread enters A2. */
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { Slots = 8, Capacity = 16384 };
typedef struct {
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[Slots];
    int busy[Slots], channels, bits, wants_start, started;
    pthread_mutex_t lock;
} Output;

static void completed(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)queue;
    Output *o = context;
    pthread_mutex_lock(&o->lock);
    for (int i = 0; i < Slots; i++) if (o->buffers[i] == buffer) o->busy[i] = 0;
    pthread_mutex_unlock(&o->lock);
}

/* A2 clients may call Start before supplying PCM. Start AudioQueue only once
 * a buffer is enqueued, so an empty queue cannot fail to start and leave the
 * producer waiting forever for callbacks from a queue that never ran. */
static OSStatus start_ready(Output *o) {
    if (!o->wants_start || o->started) return 0;
    int ready = 0;
    pthread_mutex_lock(&o->lock);
    for (int i = 0; i < Slots; i++) ready |= o->busy[i];
    pthread_mutex_unlock(&o->lock);
    if (!ready) return 0;
    OSStatus status = AudioQueueStart(o->queue, NULL);
    if (!status) o->started = 1;
    return status;
}

void a2audio_destroy(void *context) {
    Output *o = context;
    if (!o) return;
    if (o->queue) AudioQueueDispose(o->queue, true);
    pthread_mutex_destroy(&o->lock);
    free(o);
}

void *a2audio_create(int rate, int bits, int channels) {
    if (rate < 8000 || rate > 192000 || (bits != 8 && bits != 16) || channels < 1 || channels > 2) return NULL;
    Output *o = calloc(1, sizeof *o);
    if (!o) return NULL;
    pthread_mutex_init(&o->lock, NULL);
    o->channels = channels; o->bits = bits;
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate; format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsPacked | (bits == 16 ? kAudioFormatFlagIsSignedInteger : 0);
    format.mBytesPerPacket = format.mBytesPerFrame = channels * bits / 8;
    format.mFramesPerPacket = 1; format.mChannelsPerFrame = channels; format.mBitsPerChannel = bits;
    if (AudioQueueNewOutput(&format, completed, o, NULL, NULL, 0, &o->queue)) goto fail;
    for (int i = 0; i < Slots; i++)
        if (AudioQueueAllocateBuffer(o->queue, Capacity, &o->buffers[i])) goto fail;
    return o;
fail:
    a2audio_destroy(o); return NULL;
}

int a2audio_write(void *context, const void *data, int length) {
    Output *o = context;
    if (!o || !data || length < 0 || length > Capacity || length % (o->channels * o->bits / 8)) return -1;
    const char *p = data;
    while (length) {
        int slot = -1;
        pthread_mutex_lock(&o->lock);
        for (int i = 0; i < Slots; i++) if (!o->busy[i]) { slot = i; break; }
        if (slot < 0) {
            pthread_mutex_unlock(&o->lock);
            OSStatus status = start_ready(o);
            return status ? status : 1;
        }
        o->busy[slot] = 1;
        pthread_mutex_unlock(&o->lock);
        int n = length < Capacity ? length : Capacity;
        AudioQueueBufferRef b = o->buffers[slot];
        memcpy(b->mAudioData, p, n); b->mAudioDataByteSize = n;
        OSStatus status = AudioQueueEnqueueBuffer(o->queue, b, 0, NULL);
        if (status) {
            pthread_mutex_lock(&o->lock); o->busy[slot] = 0;
            pthread_mutex_unlock(&o->lock); return status;
        }
        status = start_ready(o);
        if (status) return status;
        p += n; length -= n;
    }
    return 0;
}

int a2audio_control(void *context, int command) {
    Output *o = context;
    if (!o) return -1;
    if (command == 1) { o->wants_start = 1; return start_ready(o); }
    if (command == 2) {
        o->wants_start = 0;
        OSStatus status = o->started ? AudioQueuePause(o->queue) : 0;
        if (!status) o->started = 0;
        return status;
    }
    if (command == 3) {
        OSStatus status = AudioQueueStop(o->queue, true);
        o->wants_start = o->started = 0;
        pthread_mutex_lock(&o->lock);
        memset(o->busy, 0, sizeof o->busy);
        pthread_mutex_unlock(&o->lock); return status;
    }
    if (command == 4) {
        o->wants_start = 1;
        OSStatus status = start_ready(o);
        if (status) return status;
        if (!o->started) return 0;
        status = AudioQueueStop(o->queue, false);
        if (status) return status;
        for (int i = 0; i < 1500; i++) {
            UInt32 running = 0, size = sizeof running;
            status = AudioQueueGetProperty(o->queue, kAudioQueueProperty_IsRunning, &running, &size);
            if (status || !running) return status;
            usleep(10000);
        }
        return -2;
    }
    return -1;
}

int a2audio_volume(void *context, int volume) {
    Output *o = context;
    if (!o || volume < 0 || volume > 65536) return -1;
    return AudioQueueSetParameter(o->queue, kAudioQueueParam_Volume, volume / 65536.0f);
}

int a2audio_position(void *context) {
    Output *o = context; AudioTimeStamp time = {0}; Boolean discontinuity;
    if (!o || AudioQueueGetCurrentTime(o->queue, NULL, &time, &discontinuity)) return 0;
    return time.mSampleTime > INT32_MAX ? INT32_MAX : (int)time.mSampleTime;
}
