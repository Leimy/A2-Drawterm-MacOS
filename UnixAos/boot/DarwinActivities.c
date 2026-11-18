/* Single-worker stackful activity experiment for the Darwin arm64 port. */
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include <ucontext.h>
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
