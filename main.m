// iOS memory feasibility test for a recompiled 32-bit game runtime.
//
// Answers the questions that decide whether an iOS port of MHGURecomp can work at all:
//   1. Can we reserve the 4 GB guest window at the address the PC build uses (GUEST_BASE = 1 TB, runtime/cpu.h)?
//   2. If not, can we reserve 4 GB anywhere, and at which candidate fixed bases?
//   3. Does lazy commit through a SIGSEGV/SIGBUS handler work (runtime/platform/linux.c does this)?
//   4. How much memory can we actually touch before iOS (jetsam) kills the app?
//
// Every line is also appended to Documents/memtest.log (visible in the Files app) before the risky step it
// describes, so if iOS kills the app mid-test the last line written shows how far it got. The next launch shows the
// previous run's log at the top.
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <os/proc.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define GB (1024ull * 1024ull * 1024ull)
#define MB (1024ull * 1024ull)
#define GUEST_SPACE (4ull * GB)
#define COMMIT_CHUNK 0x10000ull  // 64 KB, as in runtime/platform/linux.c

static UITextView *g_view;
static FILE *g_log;
static NSMutableString *g_text;

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void out(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (g_log) { fprintf(g_log, "%s\n", s.UTF8String); fflush(g_log); fsync(fileno(g_log)); }
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_text appendFormat:@"%@\n", s];
        g_view.text = g_text;
        [g_view scrollRangeToVisible:NSMakeRange(g_text.length, 0)];
    });
}

static NSString *mbstr(uint64_t b) { return [NSString stringWithFormat:@"%.0f MB", b / (double)MB]; }

// ---- reservation tests
static void *try_reserve(uint64_t base, uint64_t size) {
    // Darwin has no MAP_FIXED_NOREPLACE: pass the base as a hint and accept it only if the kernel honoured it.
    void *p = mmap((void *)(uintptr_t)base, size, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) return NULL;
    if (base && p != (void *)(uintptr_t)base) { munmap(p, size); return NULL; }
    return p;
}

// ---- lazy commit through the fault handler
static _Atomic uint64_t g_lo, g_hi;
static _Atomic int g_faults;

static void fault_handler(int sig, siginfo_t *si, void *uc) {
    (void)uc;
    uint64_t a = (uint64_t)(uintptr_t)si->si_addr, lo = atomic_load(&g_lo), hi = atomic_load(&g_hi);
    if (a >= lo && a < hi) {
        uint64_t c = a & ~(COMMIT_CHUNK - 1);
        if (mprotect((void *)(uintptr_t)c, COMMIT_CHUNK, PROT_READ | PROT_WRITE) == 0) {
            atomic_fetch_add(&g_faults, 1);
            return;  // retry the faulting access
        }
    }
    signal(sig, SIG_DFL);  // not ours: crash normally
}

static void run_tests(void) {
    out(@"=== iOS memtest  %@ ===", [NSDate date]);
    out(@"iOS %@, device RAM %@", UIDevice.currentDevice.systemVersion, mbstr(NSProcessInfo.processInfo.physicalMemory));
    out(@"os_proc_available_memory at start: %@", mbstr(os_proc_available_memory()));
    int sel[2] = {CTL_HW, HW_PAGESIZE}; int pg = 0; size_t len = sizeof pg;
    sysctl(sel, 2, &pg, &len, NULL, 0);
    out(@"page size: %d", pg);

    // 1-2. Reservations
    out(@"--- 1. reserve 4 GB at fixed bases");
    out(@"app image at %p", (void *)_dyld_get_image_header(0));
    const uint64_t bases[] = {0x10000000000ull /* PC GUEST_BASE, 1 TB */, 0x8000000000ull, 0x1000000000ull,
                              0x800000000ull, 0x400000000ull, 0x300000000ull /* run 1: 'anywhere' got this */,
                              0x200000000ull};
    for (size_t i = 0; i < sizeof bases / sizeof bases[0]; i++) {
        void *p = try_reserve(bases[i], GUEST_SPACE);
        out(@"  base 0x%llx: %@", bases[i], p ? @"OK" : @"FAILED");
        if (p) munmap(p, GUEST_SPACE);
    }
    out(@"--- 2. reserve 4 GB anywhere");
    void *any = try_reserve(0, GUEST_SPACE);
    out(@"  anywhere: %@", any ? [NSString stringWithFormat:@"OK at %p", any] : @"FAILED");
    if (any) munmap(any, GUEST_SPACE);
    uint64_t total = 0; int n = 0; void *blocks[64];
    while (n < 64 && (blocks[n] = try_reserve(0, GUEST_SPACE))) { total += GUEST_SPACE; n++; }
    out(@"  max total reservable in 4 GB blocks: %llu GB", total / GB);
    for (int i = 0; i < n; i++) munmap(blocks[i], GUEST_SPACE);

    // Pick the window used for the rest of the test.
    void *win = try_reserve(0x10000000000ull, GUEST_SPACE);
    if (!win) win = try_reserve(0, GUEST_SPACE);
    if (!win) { out(@"RESULT: cannot reserve a 4 GB window at all -> port is NOT feasible as designed."); return; }
    out(@"using window at %p", win);

    // Address space left next to the window, for thread stacks, GPU buffers and everything else.
    {
        uint64_t left = 0; int k = 0; static void *small[1024];
        const uint64_t blk = 64 * MB;
        while (k < 1024 && (small[k] = try_reserve(0, blk))) { left += blk; k++; }
        out(@"  address space left beside the window (64 MB blocks): %@", mbstr(left));
        for (int i = 0; i < k; i++) munmap(small[i], blk);
    }

    // 3. Lazy commit through SIGSEGV/SIGBUS
    out(@"--- 3. lazy commit via fault handler");
    atomic_store(&g_lo, (uint64_t)(uintptr_t)win);
    atomic_store(&g_hi, (uint64_t)(uintptr_t)win + GUEST_SPACE);
    struct sigaction sa = {0};
    sa.sa_sigaction = fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    volatile unsigned char *w = win;
    out(@"  touching 3 untouched pages (if the app dies here, lazy commit does not work)");
    w[0] = 1; w[GUEST_SPACE / 2] = 2; w[GUEST_SPACE - 1] = 3;
    out(@"  OK: %d faults handled, values %d %d %d", atomic_load(&g_faults), w[0], w[GUEST_SPACE / 2],
        w[GUEST_SPACE - 1]);

    // 4. How much can we really touch?
    out(@"--- 4. touch memory in 128 MB steps (stops at 3.5 GB or when <100 MB is left)");
    out(@"  if the app disappears, the last 'touched' line is the limit before iOS killed it");
    uint64_t step = 128 * MB, touched = 0;
    for (uint64_t off = 0; off + step <= GUEST_SPACE - 512 * MB; off += step) {
        if (os_proc_available_memory() < 100 * MB) { out(@"  stopping: available memory below 100 MB"); break; }
        mprotect((void *)(w + off), step, PROT_READ | PROT_WRITE);
        for (uint64_t p = 0; p < step; p += (uint64_t)pg) w[off + p] = (unsigned char)p;
        touched += step;
        out(@"  touched %@, available %@", mbstr(touched), mbstr(os_proc_available_memory()));
    }
    out(@"RESULT: touched %@ without being killed.", mbstr(touched));
    out(@"=== done ===");
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    g_view = [[UITextView alloc] initWithFrame:vc.view.bounds];
    g_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_view.editable = NO;
    g_view.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    g_view.textContainerInset = UIEdgeInsetsMake(60, 8, 40, 8);
    [vc.view addSubview:g_view];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"memtest.log"];
    NSString *prev = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    g_text = [NSMutableString new];
    if (prev.length) [g_text appendFormat:@"### previous run ###\n%@\n### new run ###\n", prev];
    g_view.text = g_text;
    g_log = fopen(path.UTF8String, "w");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ run_tests(); });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
