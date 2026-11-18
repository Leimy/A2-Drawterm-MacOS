/* Single-worker stackful activity experiment for the Darwin arm64 port. */
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include <ucontext.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <stdint.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct Pool Pool;
typedef struct Fiber Fiber;
typedef void (*Body)(void *);
typedef void (*Visit)(uintptr_t, size_t);

struct Pool {
    ucontext_t host;
    uintptr_t host_low;
    pthread_t worker;
    Fiber *first, *current;
};

struct Fiber {
    ucontext_t context;
    Pool *pool;
    Fiber *next, *prev;
    char *mapping;
    size_t total, guard;
    Body body;
    void *object;
    int done;
};

/* makecontext's variadic arguments are ints. Obtain the current fiber from
   the pinned worker instead of narrowing a pointer to an int. */
static _Thread_local Fiber *starting;

static void start(void)
{
    Fiber *f = starting;
    f->body(f->object);
    f->done = 1;
    /* uc_link restores the worker. Only the worker frees this stack. */
}

Pool *activity_pool(void)
{
    Pool *p = calloc(1, sizeof(*p));
    if (p) {
        pthread_t worker = pthread_self();
        p->worker = worker;
        p->host_low = (uintptr_t)pthread_get_stackaddr_np(worker) -
                      pthread_get_stacksize_np(worker);
    }
    return p;
}

Fiber *activity_new(Pool *p, Body body, void *object)
{
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    size_t size = 4 * page;
    Fiber *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->guard = page;
    f->total = page + size;
    f->mapping = mmap(NULL, f->total, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (f->mapping == MAP_FAILED) { free(f); return NULL; }
    if (mprotect(f->mapping + page, size, PROT_READ | PROT_WRITE) ||
        getcontext(&f->context)) {
        munmap(f->mapping, f->total);
        free(f);
        return NULL;
    }
    f->pool = p;
    f->body = body;
    f->object = object;
    f->context.uc_stack.ss_sp = f->mapping + page;
    f->context.uc_stack.ss_size = size;
    f->context.uc_link = &p->host;
    makecontext(&f->context, start, 0);
    f->next = p->first;
    if (f->next) f->next->prev = f;
    p->first = f;
    return f;
}

int activity_resume(Fiber *f)
{
    Pool *p = f->pool;
    p->current = starting = f;
    if (swapcontext(&p->host, &f->context)) abort();
    p->current = starting = NULL;
    return f->done;
}

void activity_park(Fiber *f)
{
    if (swapcontext(&f->context, &f->pool->host)) abort();
}

void activity_drop(Fiber *f)
{
    if (f->prev) f->prev->next = f->next;
    else f->pool->first = f->next;
    if (f->next) f->next->prev = f->prev;
    munmap(f->mapping, f->total);
    free(f);
}

void activity_close(Pool *p)
{
    if (p->first || p->current) abort();
    free(p);
}

/* Set once on a private connected TCP socket, before publishing it. Darwin
   send() can block for buffer space even when passed MSG_DONTWAIT. */
int activity_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

int activity_poll_socket(int fd, int writing)
{
    struct pollfd p = { .fd = fd, .events = writing ? POLLOUT : POLLIN };
    int result;
    do { result = poll(&p, 1, -1); } while (result < 0 && errno == EINTR);
    return result > 0 && !(p.revents & POLLNVAL);
}

/* A listening socket cannot be woken with shutdown on Darwin. Watch the
   socket and an explicit Close notification through one pollable queue. */
int activity_setup_queue(int fd, int writing)
{
    int q = kqueue();
    if (q < 0) return -1;
    struct kevent events[2];
    EV_SET(&events[0], fd, writing ? EVFILT_WRITE : EVFILT_READ, EV_ADD, 0, 0, NULL);
    EV_SET(&events[1], 1, EVFILT_USER, EV_ADD, 0, 0, NULL);
    if (kevent(q, events, 2, NULL, 0, NULL) < 0) {
        close(q);
        return -1;
    }
    return q;
}

int activity_cancel_setup(int q)
{
    struct kevent event;
    EV_SET(&event, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    int res;
    do { res = kevent(q, &event, 1, NULL, 0, NULL); } while (res < 0 && errno == EINTR);
    return res;
}

/* Use the same monotonic clock for the deadline check and remaining time.
   Recheck after every notification, timeout, or spurious wakeup. */
int64_t activity_now(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

void activity_wait_until(pthread_cond_t *changed, pthread_mutex_t *lock, int64_t deadline)
{
    int64_t ns = deadline - activity_now();
    if (ns <= 0) return;
    struct timespec delay = { .tv_sec = ns / 1000000000, .tv_nsec = ns % 1000000000 };
    int res = pthread_cond_timedwait_relative_np(changed, lock, &delay);
    if (res && res != ETIMEDOUT) abort();
}

/* GCD only touches native storage. The owning A2 worker picks the fiber. */
typedef struct {
    dispatch_source_t source;
    dispatch_semaphore_t stopped;
    int fd, ready;
    pthread_mutex_t *lock;
    pthread_cond_t *changed;
} SocketWatch;

static void socket_event(void *context)
{
    SocketWatch *w = context;
    dispatch_source_cancel(w->source); /* one notification per registration */
    pthread_mutex_lock(w->lock);
    w->ready = 1;
    pthread_cond_signal(w->changed);
    pthread_mutex_unlock(w->lock);
}

static void socket_cancelled(void *context)
{
    SocketWatch *w = context;
    close(w->fd);
    dispatch_semaphore_signal(w->stopped);
}

SocketWatch *activity_watch_socket(int fd, int writing, pthread_mutex_t *lock, pthread_cond_t *changed)
{
    SocketWatch *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (w->fd < 0) { free(w); return NULL; }
    w->stopped = dispatch_semaphore_create(0);
    if (w->stopped) {
        w->source = dispatch_source_create(writing ? DISPATCH_SOURCE_TYPE_WRITE : DISPATCH_SOURCE_TYPE_READ, w->fd, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    }
    if (!w->source) {
        if (w->stopped) dispatch_release(w->stopped);
        close(w->fd);
        free(w);
        return NULL;
    }
    w->lock = lock;
    w->changed = changed;
    dispatch_set_context(w->source, w);
    dispatch_source_set_event_handler_f(w->source, socket_event);
    dispatch_source_set_cancel_handler_f(w->source, socket_cancelled);
    dispatch_resume(w->source);
    return w;
}

/* The caller holds the inbox mutex. */
int activity_socket_ready(SocketWatch *w) { return w->ready; }

void activity_unwatch_socket(SocketWatch *w)
{
    dispatch_source_cancel(w->source);
    dispatch_semaphore_wait(w->stopped, DISPATCH_TIME_FOREVER);
    dispatch_release(w->source);
    dispatch_release(w->stopped);
    free(w);
}

/* Bound trap unwinding to the stack which contains the interrupted SP. */
uintptr_t activity_stack_limit(Pool *p, uintptr_t sp)
{
    Fiber *f = p->current;
    if (!f) return 0;
    uintptr_t low = (uintptr_t)f->mapping + f->guard;
    uintptr_t high = (uintptr_t)f->mapping + f->total;
    return sp >= low && sp < high ? high : 0;
}

/* Called with the A2 heaps lock and the worker stopped (or collecting
   synchronously). The host's saved SP is also valid during a fiber GC. */
void activity_roots(Pool *p, uintptr_t sp, uintptr_t bottom, Visit visit)
{
    if (pthread_equal(pthread_self(), p->worker)) {
        ucontext_t here;
        if (getcontext(&here)) abort();
        visit((uintptr_t)here.uc_mcontext, sizeof(*here.uc_mcontext));
    } else {
        /* Objects has suspended this pthread. Sample it now: the earlier
           signal frame can precede the actual stop by a context switch. */
        arm_thread_state64_t state;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(pthread_mach_thread_np(p->worker), ARM_THREAD_STATE64,
                             (thread_state_t)&state, &count) != KERN_SUCCESS) abort();
        sp = state.__sp;
        visit((uintptr_t)&state, sizeof(state));
    }
    uintptr_t host = sp;
    if (p->host.uc_mcontext && p->current) {
        uintptr_t saved = p->host.uc_mcontext->__ss.__sp;
        if (host < p->host_low || host > bottom) host = saved;
        visit((uintptr_t)p->host.uc_mcontext, sizeof(*p->host.uc_mcontext));
    }
    if (host >= p->host_low && host <= bottom) visit(host, bottom - host);
    for (Fiber *f = p->first; f; f = f->next) {
        uintptr_t low = (uintptr_t)f->mapping + f->guard;
        uintptr_t high = (uintptr_t)f->mapping + f->total;
        uintptr_t saved = f->context.uc_mcontext->__ss.__sp;
        /* A switch or signal can be in flight on the current stack. */
        uintptr_t begin = f != p->current && saved >= low && saved <= high ?
                          saved : low;
        visit(begin, high - begin);
        visit((uintptr_t)f->context.uc_mcontext, sizeof(*f->context.uc_mcontext));
        visit((uintptr_t)&f->object, sizeof(f->object));
    }
}
