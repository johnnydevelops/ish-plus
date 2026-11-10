// Tests for iSH's time syscalls, in both the time32 and time64 ABIs.
// Build and run inside iSH:  gcc -O1 time.c -o time && ./time
// Prints one line per check and exits non-zero if any failed.
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

// i386 syscall numbers, so the test does not depend on libc headers.
#define NR_getitimer 105
#define NR_timer_gettime 261
#define NR_clock_nanosleep 267
#define NR_timerfd_gettime 326
#define NR_clock_gettime 265
#define NR_clock_gettime64 403
#define NR_clock_getres_time64 406
#define NR_clock_nanosleep_time64 407
#define NR_timer_gettime64 408
#define NR_timer_settime64 409
#define NR_timerfd_gettime64 410
#define NR_timerfd_settime64 411
#define NR_utimensat_time64 412
#define NR_ppoll_time64 414
#define NR_futex_time64 422

// Raw kernel layouts. musl uses a 64-bit time_t even on i386, so libc's own
// structs cannot be passed to the time32 syscalls directly.
struct ts32 { int32_t sec; int32_t nsec; };
struct tv32 { int32_t sec; int32_t usec; };
struct itv32 { struct tv32 interval, value; };
struct its32 { struct ts32 interval, value; };
struct ts64 { int64_t sec; int64_t nsec; };
struct its64 { struct ts64 interval, value; };

static int failures;
#define CHECK(cond, ...) do { \
    if (cond) printf("ok   "); else { printf("FAIL "); failures++; } \
    printf(__VA_ARGS__); printf("\n"); \
} while (0)

static double now_mono(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(void) {
    // clock_gettime64 agrees with clock_gettime
    struct ts32 a32; struct ts64 a64;
    long r1 = syscall(NR_clock_gettime, CLOCK_REALTIME, &a32);
    long r2 = syscall(NR_clock_gettime64, CLOCK_REALTIME, &a64);
    CHECK(r1 == 0 && r2 == 0 && a64.sec - a32.sec <= 1 && a64.sec >= a32.sec,
          "clock_gettime64 (%ld %ld, %lld vs %d)", r1, r2, (long long) a64.sec, a32.sec);
    struct ts64 res;
    CHECK(syscall(NR_clock_getres_time64, CLOCK_MONOTONIC, &res) == 0 && res.sec == 0 && res.nsec > 0,
          "clock_getres_time64 (%lld ns)", (long long) res.nsec);

    // clock_nanosleep, relative and absolute, both ABIs
    double t0 = now_mono();
    struct ts32 rel32 = {0, 20000000};
    CHECK(syscall(NR_clock_nanosleep, CLOCK_MONOTONIC, 0, &rel32, NULL) == 0 && now_mono() - t0 >= 0.019,
          "clock_nanosleep relative 20ms");
    t0 = now_mono();
    struct ts64 abs64;
    syscall(NR_clock_gettime64, CLOCK_MONOTONIC, &abs64);
    abs64.nsec += 30000000;
    if (abs64.nsec >= 1000000000) { abs64.nsec -= 1000000000; abs64.sec++; }
    CHECK(syscall(NR_clock_nanosleep_time64, CLOCK_MONOTONIC, TIMER_ABSTIME, &abs64, NULL) == 0 && now_mono() - t0 >= 0.029,
          "clock_nanosleep_time64 absolute +30ms");
    struct ts64 past = {1, 0};
    CHECK(syscall(NR_clock_nanosleep_time64, CLOCK_MONOTONIC, TIMER_ABSTIME, &past, NULL) == 0,
          "clock_nanosleep_time64 absolute time in the past returns at once");
    struct ts32 bad = {0, 2000000000};
    CHECK(syscall(NR_clock_nanosleep, CLOCK_MONOTONIC, 0, &bad, NULL) == -1 && errno == EINVAL,
          "clock_nanosleep rejects tv_nsec >= 1e9");

    // libc sleep functions go through these
    t0 = now_mono();
    usleep(10000);
    struct timespec req = {0, 10000000};
    nanosleep(&req, NULL);
    CHECK(now_mono() - t0 >= 0.019, "usleep + nanosleep");

    // getitimer after setitimer
    struct itimerval set = {{0, 0}, {5, 0}};
    struct itv32 got;
    setitimer(ITIMER_REAL, &set, NULL);
    CHECK(syscall(NR_getitimer, ITIMER_REAL, &got) == 0 && got.value.sec >= 4 && got.value.sec <= 5,
          "getitimer (%d s left)", got.value.sec);
    struct itimerval off = {{0, 0}, {0, 0}};
    setitimer(ITIMER_REAL, &off, NULL);
    CHECK(syscall(NR_getitimer, ITIMER_REAL, &got) == 0 && got.value.sec == 0 && got.value.usec == 0,
          "getitimer after disarming");
    CHECK(getitimer(ITIMER_REAL, &set) == 0 && set.it_value.tv_sec == 0, "libc getitimer");

    // POSIX timers
    timer_t timer;
    struct sigevent sev = {.sigev_notify = SIGEV_NONE};
    CHECK(timer_create(CLOCK_MONOTONIC, &sev, &timer) == 0, "timer_create");
    struct its64 its = {.value = {3, 0}}, gits;
    CHECK(syscall(NR_timer_settime64, (long) timer, 0, &its, NULL) == 0, "timer_settime64");
    CHECK(syscall(NR_timer_gettime64, (long) timer, &gits) == 0 && gits.value.sec >= 2 && gits.value.sec <= 3,
          "timer_gettime64 (%lld s left)", (long long) gits.value.sec);
    struct its32 gits32;
    CHECK(syscall(NR_timer_gettime, (long) timer, &gits32) == 0 && gits32.value.sec >= 2,
          "timer_gettime");

    // timerfd
    int tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    struct its64 tits = {.value = {0, 50000000}};
    CHECK(tfd >= 0 && syscall(NR_timerfd_settime64, tfd, 0, &tits, NULL) == 0, "timerfd_settime64");
    struct its64 tgot;
    CHECK(syscall(NR_timerfd_gettime64, tfd, &tgot) == 0 && tgot.value.sec == 0 && tgot.value.nsec > 0,
          "timerfd_gettime64 (%lld ns left)", (long long) tgot.value.nsec);
    struct its32 tgot32;
    CHECK(syscall(NR_timerfd_gettime, tfd, &tgot32) == 0 && tgot32.value.nsec > 0, "timerfd_gettime");
    uint64_t expirations = 0;
    CHECK(read(tfd, &expirations, sizeof(expirations)) == 8 && expirations >= 1, "timerfd fires");
    close(tfd);

    // ppoll_time64 times out
    int fds[2];
    pipe(fds);
    struct pollfd pfd = {.fd = fds[0], .events = POLLIN};
    struct ts64 pto = {0, 20000000};
    t0 = now_mono();
    CHECK(syscall(NR_ppoll_time64, &pfd, 1, &pto, NULL, 8) == 0 && now_mono() - t0 >= 0.015,
          "ppoll_time64 timeout");

    // futex_time64 wait times out
    int futex_word = 0;
    struct ts64 fto = {0, 20000000};
    t0 = now_mono();
    long fr = syscall(NR_futex_time64, &futex_word, 0 /* FUTEX_WAIT */, 0, &fto, NULL, 0);
    CHECK(fr == -1 && errno == ETIMEDOUT && now_mono() - t0 >= 0.015, "futex_time64 timeout (errno %d)", errno);

    // utimensat_time64 sets the modification time
    int f = open("/tmp/ish-time-test", O_CREAT | O_WRONLY, 0644);
    close(f);
    struct ts64 times[2] = {{1000000000, 0}, {1234567890, 0}};
    struct stat st;
    CHECK(syscall(NR_utimensat_time64, AT_FDCWD, "/tmp/ish-time-test", times, 0) == 0 &&
          stat("/tmp/ish-time-test", &st) == 0 && st.st_mtime == 1234567890,
          "utimensat_time64 (mtime %ld)", (long) st.st_mtime);
    unlink("/tmp/ish-time-test");

    printf("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures != 0;
}
