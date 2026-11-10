//
//  JITProbe.c
//  iSH+
//
//  Diagnostics: tries the ways of getting executable memory on iOS and
//  reports which ones actually run code on this device, so the QEMU JIT can
//  use one that works. Results are written to stderr (Documents/VM/qemu.log).
//

#include "JITProbe.h"
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t, int,
                                   vm_map_t, mach_vm_address_t, boolean_t, vm_prot_t *, vm_prot_t *, vm_inherit_t);

// mov w0, #42 ; ret
static const uint32_t code[] = { 0x52800540, 0xd65f03c0 };
#define SIZE 0x4000

struct attempt {
    int (*fn)(void);
    volatile int state; // 0 running, 1 returned, 2 faulted
    volatile int result;
};

static __thread sigjmp_buf *probe_jump;

static void probe_signal(int sig) {
    if (probe_jump)
        siglongjmp(*probe_jump, sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void *run_attempt(void *arg) {
    struct attempt *a = arg;
    sigjmp_buf jump;
    int sig = sigsetjmp(jump, 1);
    if (sig == 0) {
        probe_jump = &jump;
        a->result = a->fn();
        a->state = 1;
    } else {
        a->result = sig;
        a->state = 2;
    }
    probe_jump = NULL;
    return NULL;
}

static const char *call(void *rx) {
    static struct attempt a;
    a = (struct attempt) { .fn = (int (*)(void)) rx };
    pthread_t thread;
    pthread_create(&thread, NULL, run_attempt, &a);
    for (int i = 0; i < 100 && a.state == 0; i++)
        usleep(10000);
    if (a.state == 0)
        return "STUCK (no return after 1 s)";
    static char fault[32];
    if (a.state == 2) {
        snprintf(fault, sizeof(fault), "FAULT (signal %d)", a.result);
        return fault;
    }
    return a.result == 42 ? "WORKS" : "WRONG RESULT";
}

static void report(const char *name, const char *outcome) {
    fprintf(stderr, "JIT probe [%ld] %s: %s\n", (long) time(NULL), name, outcome);
}

static void write_and_call(const char *name, void *rw, void *rx) {
    memcpy(rw, code, sizeof(code));
    sys_dcache_flush(rw, sizeof(code));
    sys_icache_invalidate(rx, sizeof(code));
    report(name, call(rx));
}

static mach_vm_address_t remap(void *source) {
    mach_vm_address_t alias = 0;
    vm_prot_t cur, max;
    kern_return_t ret = mach_vm_remap(mach_task_self(), &alias, SIZE, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                      (mach_vm_address_t) source, FALSE, &cur, &max, VM_INHERIT_NONE);
    return ret == KERN_SUCCESS ? alias : 0;
}

void jit_probe_run(void) {
    struct sigaction sa = { .sa_handler = probe_signal };
    sigemptyset(&sa.sa_mask);
    struct sigaction old_bus, old_segv, old_ill;
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGILL, &sa, &old_ill);

    // A: executable mapping first, writable mirror (Dolphin's order)
    {
        void *rx = mmap(NULL, SIZE, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        mach_vm_address_t rw = rx == MAP_FAILED ? 0 : remap(rx);
        if (rx == MAP_FAILED) report("A rx-first", strerror(errno));
        else if (!rw) report("A rx-first", "remap failed");
        else if (mprotect((void *) rw, SIZE, PROT_READ | PROT_WRITE)) report("A rx-first", strerror(errno));
        else write_and_call("A rx-first", (void *) rw, rx);
    }
    // B: writable mapping first, executable mirror (upstream QEMU's order)
    {
        void *rw = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        mach_vm_address_t rx = rw == MAP_FAILED ? 0 : remap(rw);
        if (!rx) report("B rw-first", "remap failed");
        else if (mprotect((void *) rx, SIZE, PROT_READ | PROT_EXEC)) report("B rw-first", strerror(errno));
        else write_and_call("B rw-first", rw, (void *) rx);
    }
    // C: one mapping, write then make it executable
    {
        void *p = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        memcpy(p, code, sizeof(code));
        if (mprotect(p, SIZE, PROT_READ | PROT_EXEC)) report("C toggle", strerror(errno));
        else { sys_icache_invalidate(p, sizeof(code)); report("C toggle", call(p)); }
    }
    // D: one mapping that is writable and executable
    {
        void *p = mmap(NULL, SIZE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) report("D rwx", strerror(errno));
        else write_and_call("D rwx", p, p);
    }
    // E: like B but mapped executable first (UTM's iOS 26 change)
    {
        void *orig = mmap(NULL, SIZE, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        mach_vm_address_t rx = orig == MAP_FAILED ? 0 : remap(orig);
        if (!rx) report("E utm-ios26", "remap failed");
        else if (mprotect((void *) rx, SIZE, PROT_READ | PROT_EXEC)) report("E utm-ios26", strerror(errno));
        else if (mprotect(orig, SIZE, PROT_READ | PROT_WRITE)) report("E utm-ios26", strerror(errno));
        else write_and_call("E utm-ios26", orig, (void *) rx);
    }

    sigaction(SIGBUS, &old_bus, NULL);
    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGILL, &old_ill, NULL);
}
