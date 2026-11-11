// libfaketime.dylib — 通过 DYLD_INSERT_LIBRARIES 注入目标进程，
// 拦截获取“墙上时间”的函数，让该进程看到伪造的日期时间。
// 系统时钟本身不受影响。
//
// 环境变量（由启动器设置）：
//   RAD_TIME          伪造的起始时间，Unix 时间戳（秒，可带小数）
//   RAD_FREEZE        =1 时时间冻结在 RAD_TIME，不随真实时间流逝
//   RAD_RETURN_AFTER  >0 时，进程启动该秒数后恢复真实时间
//   RAD_REAL_START    （内部）首个进程启动时的真实时间（纳秒），子进程共享同一锚点

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

#define DYLD_INTERPOSE(_replacement, _replacee)                                  \
    __attribute__((used)) static struct {                                        \
        const void *replacement;                                                 \
        const void *replacee;                                                    \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement,                              \
        (const void *)(unsigned long)&_replacee};

#define RAD_NSEC 1000000000LL

static int g_enabled = 0;
static int g_freeze = 0;
static int64_t g_target_ns = 0;
static int64_t g_real_start_ns = 0;
static int64_t g_return_after_ns = 0;

// 注意：dyld 不会对“执行插桩的镜像自身”应用 interpose，
// 所以这里调用 clock_gettime_nsec_np 拿到的是真实时间。
static int64_t real_now_ns(void) {
    return (int64_t)clock_gettime_nsec_np(CLOCK_REALTIME);
}

static int64_t fake_from_real(int64_t real) {
    if (!g_enabled) return real;
    int64_t elapsed = real - g_real_start_ns;
    if (g_return_after_ns > 0 && elapsed >= g_return_after_ns) return real;
    if (g_freeze) return g_target_ns;
    return g_target_ns + elapsed;
}

static int64_t fake_now_ns(void) { return fake_from_real(real_now_ns()); }

__attribute__((constructor)) static void rad_init(void) {
    const char *t = getenv("RAD_TIME");
    if (!t || !*t) return;
    g_target_ns = (int64_t)(strtod(t, NULL) * (double)RAD_NSEC);

    const char *f = getenv("RAD_FREEZE");
    g_freeze = (f && f[0] == '1');

    const char *r = getenv("RAD_RETURN_AFTER");
    if (r && *r) g_return_after_ns = (int64_t)(strtod(r, NULL) * (double)RAD_NSEC);

    const char *s = getenv("RAD_REAL_START");
    if (s && *s) {
        g_real_start_ns = strtoll(s, NULL, 10);
    } else {
        g_real_start_ns = real_now_ns();
        char buf[32];
        snprintf(buf, sizeof buf, "%lld", (long long)g_real_start_ns);
        setenv("RAD_REAL_START", buf, 1);  // 让子进程沿用同一时间锚点
    }
    g_enabled = 1;
}

// ---- 被替换的函数 ----

static time_t rad_time(time_t *tloc) {
    time_t v = (time_t)(fake_now_ns() / RAD_NSEC);
    if (tloc) *tloc = v;
    return v;
}
DYLD_INTERPOSE(rad_time, time)

static int rad_gettimeofday(struct timeval *restrict tp, void *restrict tzp) {
    int rc = gettimeofday(tp, tzp);
    if (rc == 0 && tp && g_enabled) {
        int64_t real = (int64_t)tp->tv_sec * RAD_NSEC + (int64_t)tp->tv_usec * 1000;
        int64_t fake = fake_from_real(real);
        tp->tv_sec = (time_t)(fake / RAD_NSEC);
        tp->tv_usec = (suseconds_t)((fake % RAD_NSEC) / 1000);
    }
    return rc;
}
DYLD_INTERPOSE(rad_gettimeofday, gettimeofday)

static int rad_clock_gettime(clockid_t clk, struct timespec *tp) {
    int rc = clock_gettime(clk, tp);
    if (rc == 0 && tp && g_enabled && clk == CLOCK_REALTIME) {
        int64_t real = (int64_t)tp->tv_sec * RAD_NSEC + tp->tv_nsec;
        int64_t fake = fake_from_real(real);
        tp->tv_sec = (time_t)(fake / RAD_NSEC);
        tp->tv_nsec = (long)(fake % RAD_NSEC);
    }
    return rc;
}
DYLD_INTERPOSE(rad_clock_gettime, clock_gettime)

static uint64_t rad_clock_gettime_nsec_np(clockid_t clk) {
    uint64_t v = clock_gettime_nsec_np(clk);
    if (g_enabled && clk == CLOCK_REALTIME && v != 0) return (uint64_t)fake_from_real((int64_t)v);
    return v;
}
DYLD_INTERPOSE(rad_clock_gettime_nsec_np, clock_gettime_nsec_np)

// Foundation 的 NSDate / Swift 的 Date() 最终走这里
static CFAbsoluteTime rad_CFAbsoluteTimeGetCurrent(void) {
    if (!g_enabled) return CFAbsoluteTimeGetCurrent();
    return (double)fake_now_ns() / (double)RAD_NSEC - kCFAbsoluteTimeIntervalSince1970;
}
DYLD_INTERPOSE(rad_CFAbsoluteTimeGetCurrent, CFAbsoluteTimeGetCurrent)
