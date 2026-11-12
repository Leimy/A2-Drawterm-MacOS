/* Bounded HTTP transport for Active Oberon. TLS validation uses system libcurl. */
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <limits.h>

enum { Capacity = 65536 };
typedef struct {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t ready;
    char *url;
    unsigned char bytes[Capacity];
    size_t head, count;
    int cancelled, finished, headers, interval, result, unsupported;
    long status;
} Radio;
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

static int type_is(const char *p, const char *type) {
    size_t n = strlen(type);
    return !strncasecmp(p, type, n) && (p[n] == ';' || p[n] == ' ' || p[n] == '\r' || p[n] == '\n');
}

static int progress(void *arg, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    Radio *r = arg;
    pthread_mutex_lock(&r->lock); int cancelled = r->cancelled; pthread_mutex_unlock(&r->lock);
    return cancelled;
}

static size_t header(char *p, size_t size, size_t count, void *arg) {
    Radio *r = arg; size_t n = size * count;
    pthread_mutex_lock(&r->lock);
    if ((n >= 5 && !strncasecmp(p, "HTTP/", 5)) || (n >= 4 && !strncasecmp(p, "ICY ", 4))) {
        r->interval = 0; r->unsupported = 0;
        char *space = memchr(p, ' ', n); r->status = space ? strtol(space + 1, NULL, 10) : 0;
    } else if (n > 14 && !strncasecmp(p, "content-type:", 13)) {
        char *value = p + 13;
        while (*value == ' ' || *value == '\t') value++;
        r->unsupported = !(type_is(value, "audio/mpeg") || type_is(value, "audio/mp3") ||
                          type_is(value, "audio/x-mpeg") || type_is(value, "application/octet-stream") ||
                          type_is(value, "binary/octet-stream") || type_is(value, "audio/aac") ||
                          type_is(value, "audio/aacp") || type_is(value, "audio/x-aac") ||
                          type_is(value, "audio/ogg") || type_is(value, "application/ogg") ||
                          type_is(value, "audio/opus") || type_is(value, "audio/flac") ||
                          type_is(value, "audio/x-flac"));
    } else if (n > 12 && !strncasecmp(p, "icy-metaint:", 12)) {
        long v = strtol(p + 12, NULL, 10);
        r->interval = v >= 0 && v <= 16777216 ? (int)v : -1;
    }
    pthread_mutex_unlock(&r->lock);
    return n;
}

static size_t body(char *p, size_t size, size_t count, void *arg) {
    Radio *r = arg; size_t n = size * count, copied = 0;
    pthread_mutex_lock(&r->lock);
    if (r->status != 200 || r->interval < 0 || r->unsupported) { pthread_mutex_unlock(&r->lock); return 0; }
    r->headers = 1; pthread_cond_broadcast(&r->ready);
    while (copied < n && !r->cancelled) {
        while (r->count == Capacity && !r->cancelled) pthread_cond_wait(&r->ready, &r->lock);
        if (r->cancelled) break;
        size_t tail = (r->head + r->count) % Capacity, take = n - copied;
        if (take > Capacity - r->count) take = Capacity - r->count;
        if (take > Capacity - tail) take = Capacity - tail;
        memcpy(r->bytes + tail, p + copied, take); r->count += take; copied += take;
        pthread_cond_broadcast(&r->ready);
    }
    pthread_mutex_unlock(&r->lock);
    return copied;
}

static void *fetch(void *arg) {
    Radio *r = arg;
    CURL *curl = curl_easy_init();
    struct curl_slist *request = NULL, *aliases = NULL;
    CURLcode result = CURLE_FAILED_INIT;
    if (curl) {
        request = curl_slist_append(request, "Icy-MetaData: 1");
        aliases = curl_slist_append(aliases, "ICY 200 OK");
        curl_easy_setopt(curl, CURLOPT_URL, r->url);
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, request);
        curl_easy_setopt(curl, CURLOPT_HTTP200ALIASES, aliases);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "DarwinA2-RadioGlobe/1");
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
        /* macOS 13 system libcurl predates the *_PROTOCOLS_STR options. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
        curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#pragma clang diagnostic pop
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
        curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 15L);
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
        curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, header);
        curl_easy_setopt(curl, CURLOPT_HEADERDATA, r);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, body);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, r);
        curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progress);
        curl_easy_setopt(curl, CURLOPT_XFERINFODATA, r);
        curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
        result = curl_easy_perform(curl);
        curl_easy_cleanup(curl);
    }
    curl_slist_free_all(request); curl_slist_free_all(aliases);
    pthread_mutex_lock(&r->lock);
    r->result = result; r->finished = 1;
    pthread_cond_broadcast(&r->ready); pthread_mutex_unlock(&r->lock);
    return NULL;
}

void *a2radio_create(const char *url) {
    if (!url || (strncmp(url, "http://", 7) && strncmp(url, "https://", 8)) || strlen(url) > 8192) return NULL;
    pthread_once(&initialized, initialize);
    Radio *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->url = strdup(url);
    if (!r->url) { free(r); return NULL; }
    pthread_mutex_init(&r->lock, NULL); pthread_cond_init(&r->ready, NULL);
    if (pthread_create(&r->thread, NULL, fetch, r)) {
        pthread_cond_destroy(&r->ready); pthread_mutex_destroy(&r->lock); free(r->url); free(r); return NULL;
    }
    return r;
}

int a2radio_interval(void *context) {
    Radio *r = context;
    pthread_mutex_lock(&r->lock);
    while (!r->headers && !r->finished && !r->cancelled) pthread_cond_wait(&r->ready, &r->lock);
    int value = r->headers ? r->interval : -1;
    pthread_mutex_unlock(&r->lock); return value;
}

int a2radio_prefill(void *context) {
    Radio *r = context;
    pthread_mutex_lock(&r->lock);
    while (r->count < 16384 && !r->finished && !r->cancelled) pthread_cond_wait(&r->ready, &r->lock);
    int n = r->cancelled ? 0 : (int)r->count;
    pthread_mutex_unlock(&r->lock); return n;
}

int a2radio_read(void *context, void *data, int length) {
    Radio *r = context;
    if (!r || !data || length <= 0) return -1;
    pthread_mutex_lock(&r->lock);
    while (!r->count && !r->finished && !r->cancelled) pthread_cond_wait(&r->ready, &r->lock);
    size_t n = length;
    if (n > r->count) n = r->count;
    if (n > Capacity - r->head) n = Capacity - r->head;
    if (r->cancelled) n = 0;
    memcpy(data, r->bytes + r->head, n); r->head = (r->head + n) % Capacity; r->count -= n;
    int result = n ? (int)n : (r->finished && r->result && !r->cancelled ? -1 : 0);
    pthread_cond_broadcast(&r->ready); pthread_mutex_unlock(&r->lock); return result;
}

void a2radio_cancel(void *context) {
    Radio *r = context;
    pthread_mutex_lock(&r->lock); r->cancelled = 1; pthread_cond_broadcast(&r->ready); pthread_mutex_unlock(&r->lock);
}

void a2radio_destroy(void *context) {
    Radio *r = context;
    if (!r) return;
    a2radio_cancel(r); pthread_join(r->thread, NULL);
    pthread_cond_destroy(&r->ready); pthread_mutex_destroy(&r->lock); free(r->url); free(r);
}
