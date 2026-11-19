/* Linux/glibc backend for the Unix A2 activity scheduler. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

static uintptr_t host_stack_low(pthread_t worker)
{
    pthread_attr_t attr;
    void *base;
    size_t size;
    if (pthread_getattr_np(worker, &attr) ||
        pthread_attr_getstack(&attr, &base, &size)) abort();
    pthread_attr_destroy(&attr);
    return (uintptr_t)base;
}

#include "UnixActivityFibers.inc"

static void visit_current_registers(Visit visit)
{
    ucontext_t here;
    if (getcontext(&here)) abort();
    visit((uintptr_t)&here, sizeof(here));
}

void activity_roots(Pool *p, uintptr_t sp, uintptr_t bottom, Visit visit)
{
    if (pthread_equal(pthread_self(), p->worker)) {
        visit_current_registers(visit);
    }
    /* Objects scanned the register image from the suspend signal on remote
       workers. Include the interrupted SysV red zone when on the host. */
    if (sp >= p->host_low && sp <= bottom) {
        if (sp - p->host_low >= 128) sp -= 128;
    } else if (p->current) {
        sp = p->host_mark;
    }
    if (sp >= p->host_low && sp <= bottom) visit(sp, bottom - sp);
    if (p->current) visit((uintptr_t)&p->host, sizeof(p->host));
    for (Fiber *f = p->first; f; f = f->next) {
        visit((uintptr_t)f->mapping + f->guard, f->total - f->guard);
        visit((uintptr_t)&f->context, sizeof(f->context));
        visit((uintptr_t)&f->object, sizeof(f->object));
    }
}

void activity_wait_until(pthread_cond_t *changed, pthread_mutex_t *lock, int64_t deadline)
{
    struct timespec until = { deadline / 1000000000, deadline % 1000000000 };
    int r = pthread_cond_clockwait(changed, lock, CLOCK_MONOTONIC, &until);
    if (r && r != ETIMEDOUT) abort();
}

typedef struct {
    struct pollfd fds[2];
    pthread_t thread;
    int ready;
    pthread_mutex_t *lock;
    pthread_cond_t *changed;
} SocketWatch;

static void *watch(void *arg)
{
    SocketWatch *w = arg;
    int r;
    do { r = poll(w->fds, 2, -1); } while (r < 0 && errno == EINTR);
    if (r < 0 || w->fds[0].revents) {
        pthread_mutex_lock(w->lock);
        w->ready = 1;
        pthread_cond_signal(w->changed);
        pthread_mutex_unlock(w->lock);
    }
    return NULL;
}

SocketWatch *activity_watch_socket(int fd, int writing, pthread_mutex_t *lock, pthread_cond_t *changed)
{
    SocketWatch *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->fds[0] = (struct pollfd){ .fd = fcntl(fd, F_DUPFD_CLOEXEC, 0),
                                 .events = writing ? POLLOUT : POLLIN };
    w->fds[1] = (struct pollfd){ .fd = eventfd(0, EFD_CLOEXEC), .events = POLLIN };
    w->lock = lock;
    w->changed = changed;
    if (w->fds[0].fd < 0 || w->fds[1].fd < 0 || pthread_create(&w->thread, NULL, watch, w)) {
        if (w->fds[0].fd >= 0) close(w->fds[0].fd);
        if (w->fds[1].fd >= 0) close(w->fds[1].fd);
        free(w);
        return NULL;
    }
    return w;
}

int activity_socket_ready(SocketWatch *w) { return w->ready; }

void activity_unwatch_socket(SocketWatch *w)
{
    int r;
    do { r = eventfd_write(w->fds[1].fd, 1); } while (r < 0 && errno == EINTR);
    if (r < 0 || pthread_join(w->thread, NULL)) abort();
    close(w->fds[0].fd);
    close(w->fds[1].fd);
    free(w);
}
