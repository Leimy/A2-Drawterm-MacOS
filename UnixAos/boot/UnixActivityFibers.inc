/* Shared by the Unix platform backends. The includer supplies host_stack_low. */
typedef struct Pool Pool;
typedef struct Fiber Fiber;
typedef void (*Body)(void *);
typedef void (*Visit)(uintptr_t, size_t);

struct Pool {
    ucontext_t host;
    uintptr_t host_low, host_mark;
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
        p->host_low = host_stack_low(worker);
    }
    return p;
}

/* The captured instruction pointer is replaced by makecontext before use. */
static int initialize_context(Fiber *f)
{
    if (getcontext(&f->context)) return -1;
    f->context.uc_stack.ss_sp = f->mapping + f->guard;
    f->context.uc_stack.ss_size = f->total - f->guard;
    f->context.uc_link = &f->pool->host;
    makecontext(&f->context, start, 0);
    return 0;
}

Fiber *activity_new(Pool *p, Body body, void *object)
{
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    size_t size = page > 16384 ? 4 * page : 65536;
    Fiber *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->guard = page;
    f->total = page + size;
    f->mapping = mmap(NULL, f->total, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (f->mapping == MAP_FAILED) { free(f); return NULL; }
    f->pool = p;
    if (mprotect(f->mapping + page, size, PROT_READ | PROT_WRITE) ||
        initialize_context(f)) {
        munmap(f->mapping, f->total);
        free(f);
        return NULL;
    }
    f->body = body;
    f->object = object;
    f->next = p->first;
    if (f->next) f->next->prev = f;
    p->first = f;
    return f;
}

int activity_resume(Fiber *f)
{
    Pool *p = f->pool;
    p->host_mark = (uintptr_t)&p;
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

int64_t activity_now(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
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
