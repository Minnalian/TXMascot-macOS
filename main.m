// TXMascot for macOS v3 — 天选姬桌宠
// v3 新增: 开机自启动 / 位置设置记忆 / 定时提醒 / 找茬计分 / 换装 / 猫咪彩蛋 / 双击交互 / 全局快捷键
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <ServiceManagement/SMAppService.h>
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>

// ============================ 工具 ============================

static NSArray<NSString *> *LoadVoiceNames(void) {
    NSString *dir = [[[[NSBundle mainBundle] resourceURL] path] stringByAppendingString:@"/Sound/Voice"];
    NSArray *f = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    return [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.wav'"]];
}

static void PlayRandomVoice(void) {
    static AVAudioPlayer *player = nil;
    NSArray *voices = LoadVoiceNames();
    if (!voices.count) return;
    NSString *dir = [[[[NSBundle mainBundle] resourceURL] path] stringByAppendingString:@"/Sound/Voice"];
    NSString *pick = voices[(NSUInteger)arc4random_uniform((u_int32_t)voices.count)];
    NSString *path = [dir stringByAppendingPathComponent:pick];
    player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    [player setVolume:0.9];
    [player play];
}

static NSString *VoiceNamed(NSString *prefix) {
    NSArray *voices = [LoadVoiceNames() filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", prefix]];
    if (!voices.count) return nil;
    return voices[(NSUInteger)arc4random_uniform((u_int32_t)voices.count)];
}

// ============================ 偏好持久化 ============================

static NSString *PrefsPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TXMascot/prefs.plist"];
}
static NSMutableDictionary *LoadPrefs(void) {
    return [[NSMutableDictionary dictionaryWithContentsOfFile:PrefsPath()] mutableCopy] ?: [NSMutableDictionary dictionary];
}
static void SavePrefs(NSDictionary *p) {
    NSString *dir = [PrefsPath() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [p writeToFile:PrefsPath() atomically:YES];
}

// 系统状态: CPU%
static double SysCPULoad(void) {
    static processor_info_array_t prev = nil;
    static mach_msg_type_number_t prevCount = 0;
    natural_t numCPU = 0;
    processor_info_array_t info = nil;
    mach_msg_type_number_t count = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &count) != KERN_SUCCESS) return -1;
    double busy = 0, total = 0;
    for (natural_t i = 0; i < numCPU; i++) {
        integer_t *cur = &info[i * CPU_STATE_MAX];
        integer_t *old = prev ? &prev[i * CPU_STATE_MAX] : NULL;
        int states[] = {CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_NICE, CPU_STATE_IDLE};
        double s[4] = {0, 0, 0, 0};
        for (int k = 0; k < 4; k++) s[k] = cur[states[k]] - (old ? old[states[k]] : cur[states[k]]);
        double t = s[0] + s[1] + s[2] + s[3];
        if (t > 0) { total += t; busy += s[0] + s[1] + s[2]; }
    }
    if (prev) vm_deallocate(mach_task_self(), (vm_address_t)prev, prevCount * sizeof(integer_t));
    prev = info; prevCount = count;
    if (total <= 0) return -1;
    return (busy / total) * 100.0;
}

static double SysRAMUsed(void) {
    vm_statistics64_data_t vmstat;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmstat, &cnt) != KERN_SUCCESS) return -1;
    int64_t used = (vmstat.active_count + vmstat.wire_count + vmstat.compressor_page_count) * 4096;
    int64_t totalMem = 0;
    size_t len = sizeof(totalMem);
    sysctlbyname("hw.memsize", &totalMem, &len, NULL, 0);
    if (totalMem <= 0) return -1;
    return (double)used / (double)totalMem * 100.0;
}

// ============================ 帧动画视图 ============================

@interface MascotView : NSView
@property (strong) NSMutableDictionary<NSString *, NSArray<NSImage *> *> *clips;
@property (strong) NSMutableArray<NSString *> *idleNames;
@property (strong) NSMutableArray<NSString *> *fancyNames;
@property (strong) NSMutableArray<NSString *> *walkNames;
@property (strong) NSMutableArray<NSString *> *suitIdleNames;
@property (strong) NSMutableArray<NSString *> *suitFancyNames;
@property (assign) BOOL suitMode;
@property (strong) NSString *currentClip;
@property (assign) NSInteger frameIdx;
@property (assign) NSTimeInterval lastFrameTime;
@property (assign) CGFloat scale;
@property (assign) CGFloat opacity;
@property (weak) NSWindow *hostWindow;
@property (assign) NSPoint dragStartMouse;
@property (assign) NSPoint dragStartOrigin;
@property (assign) BOOL dragActive;
@property (strong) NSTimer *timer;
@property (assign) BOOL oneshot;
@property (assign) BOOL walkOn;
@property (assign) CGFloat walkDir;
@property (assign) BOOL mirrored;
@property (assign) NSPoint walkTarget;
@property (assign) NSTimeInterval walkRetargetAt;
- (void)playClip:(NSString *)name;
- (void)playNamed:(NSString *)name;
- (void)playIdle;
- (void)applyCostumeChange;
- (NSArray<NSString *> *)activeIdlePool;
- (NSArray<NSString *> *)activeFancyPool;
- (void)playFancy;
- (void)playSuitShow;
- (void)setWalk:(BOOL)on;
@end

@implementation MascotView

+ (NSInteger)clampIndex:(NSInteger)i count:(NSInteger)c {
    if (i < 0) return 0;
    if (i >= c) return c - 1;
    return i;
}

- (instancetype)init {
    self = [super initWithFrame:NSMakeRect(0, 0, 300, 300)];
    if (self) {
        _clips = [NSMutableDictionary dictionary];
        _idleNames = [NSMutableArray array];
        _fancyNames = [NSMutableArray array];
        _walkNames = [NSMutableArray array];
        _suitIdleNames = [NSMutableArray array];
        _suitFancyNames = [NSMutableArray array];
        _scale = 1.0;
        _opacity = 1.0;
        _walkDir = 1.0;
        _walkTarget = NSMakePoint(-1, -1);
        [self loadAssets];
        [self playIdle];
        _timer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)loadAssets {
    NSString *root = [[[NSBundle mainBundle] resourceURL] path];
    if (!root) root = [[NSBundle mainBundle] bundlePath];
    NSString *actions = [root stringByAppendingPathComponent:@"Actions"];
    NSArray *groups = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:actions error:nil];
    NSArray *idlePrefix = @[@"RandomStand", @"RandomSit", @"Basic"];
    // 随机表演池: 不含 HideSomething(带全透明帧会凭空消失=闪烁) 和 WalkAround/WAM(散步/猫专用)
    NSArray *fancyPrefix = @[@"Simple", @"Event", @"InteractiveStand", @"InteractiveSit",
                             @"EatSomething", @"Gift", @"FNewYear", @"FMoon",
                             @"FChristmas", @"FLabor", @"FLantern", @"FDragonBoat",
                             @"FChineseValentines", @"FChildren"];
    for (NSString *g in [groups sortedArrayUsingSelector:@selector(compare:)]) {
        if (![g hasSuffix:@".frames"]) continue;
        NSString *dir = [actions stringByAppendingPathComponent:g];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.png'"]];
        files = [files sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *frames = [NSMutableArray array];
        for (NSString *f in files) {
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
            if (img) [frames addObject:img];
        }
        if (!frames.count) continue;
        NSString *name = [g stringByReplacingOccurrencesOfString:@".frames" withString:@""];
        self.clips[name] = frames;
        if ([name hasPrefix:@"DailySuit"]) {
            // 换装版动作池: 待机收 RandomStand/RandomSit/Basic，表演收其余全部
            if ([name hasPrefix:@"DailySuit_RandomStand"] || [name hasPrefix:@"DailySuit_RandomSit"] ||
                [name hasPrefix:@"DailySuit_Basic"])
                [self.suitIdleNames addObject:name];
            // HideSomething 带全透明帧会凭空消失（闪烁），不进换装表演池
            if (![name hasPrefix:@"DailySuit_HideSomething"])
                [self.suitFancyNames addObject:name];
            continue;
        }
        for (NSString *p in idlePrefix) if ([name hasPrefix:p]) { [self.idleNames addObject:name]; break; }
        for (NSString *p in fancyPrefix) if ([name hasPrefix:p]) { [self.fancyNames addObject:name]; break; }
        // 散步池只收迈步循环 WalkAround_2/3/5/6；_1/_4 是站立挥手，WAM_* 是猫
        if ([name hasPrefix:@"WalkAround"] &&
            ![name isEqualToString:@"WalkAround_1"] && ![name isEqualToString:@"WalkAround_4"])
            [self.walkNames addObject:name];
    }
}

- (void)playNamed:(NSString *)name {
    if (!self.clips[name]) return;
    NSLog(@"[TX] playNamed -> %@ (%lu frames)", name, (unsigned long)self.clips[name].count);
    { FILE *f = fopen("/tmp/tx_build/picks.txt", "a"); if (f) { fprintf(f, "%s\n", name.UTF8String); fclose(f); } }
    self.currentClip = name;
    self.frameIdx = 0;
    self.lastFrameTime = [NSDate timeIntervalSinceReferenceDate];
    self.oneshot = YES;
}

- (void)playClip:(NSString *)name {
    if (!self.clips[name]) return;
    self.currentClip = name;
    self.frameIdx = 0;
    self.lastFrameTime = [NSDate timeIntervalSinceReferenceDate];
    self.oneshot = NO;
}

// 当前服装生效的动作池：换装时优先用 DailySuit 池，池为空则回落原版
- (NSArray<NSString *> *)activeIdlePool {
    return (self.suitMode && self.suitIdleNames.count) ? self.suitIdleNames : self.idleNames;
}
- (NSArray<NSString *> *)activeFancyPool {
    return (self.suitMode && self.suitFancyNames.count) ? self.suitFancyNames : self.fancyNames;
}

- (void)playIdle {
    self.mirrored = NO;
    NSArray<NSString *> *pool = [self activeIdlePool];
    NSString *n = pool.count
        ? pool[(NSUInteger)arc4random_uniform((u_int32_t)pool.count)]
        : self.clips.allKeys.firstObject;
    [self playClip:n];
}

- (void)playFancy {
    NSArray<NSString *> *pool = [self activeFancyPool];
    if (!pool.count) return;
    [self playNamed:pool[(NSUInteger)arc4random_uniform((u_int32_t)pool.count)]];
}

- (void)playSuitShow {
    if (!self.suitFancyNames.count) return;
    [self playNamed:self.suitFancyNames[(NSUInteger)arc4random_uniform((u_int32_t)self.suitFancyNames.count)]];
}

- (void)setWalk:(BOOL)on {
    self.walkOn = on;
    if (on) {
        // 开走时先落到地面，随后由 tick 里的随机目标点接管（上下左右漫游）
        NSWindow *w = self.hostWindow;
        NSScreen *scr = w.screen ?: NSScreen.mainScreen;
        NSRect vf = scr.visibleFrame;
        NSRect f = w.frame;
        f.origin.y = vf.origin.y + 10;
        [w setFrameOrigin:f.origin];
        self.walkTarget = NSMakePoint(-1, -1);
        self.walkRetargetAt = 0;
        self.mirrored = NO;
        NSString *n = self.walkNames.count
            ? self.walkNames[(NSUInteger)arc4random_uniform((u_int32_t)self.walkNames.count)]
            : nil;
        if (n) [self playClip:n];
    } else {
        self.mirrored = NO;
        [self playIdle];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TXWalkChanged" object:@(on)];
}

// 换装后立即以新服装重放当前状态（散步中换走路段，否则换待机）
- (void)applyCostumeChange {
    if (self.walkOn) {
        NSString *n = self.walkNames.count
            ? self.walkNames[(NSUInteger)arc4random_uniform((u_int32_t)self.walkNames.count)] : nil;
        if (n) [self playClip:n];
    } else {
        [self playIdle];
    }
}

- (void)tick:(NSTimer *)t {
    NSArray<NSImage *> *frames = self.clips[self.currentClip];
    if (frames.count == 0) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.lastFrameTime == 0) self.lastFrameTime = now;
    BOOL step = now - self.lastFrameTime >= 1.0 / 12.0;

    if (self.walkOn && step) {
        NSWindow *w = self.hostWindow;
        // 在她当前所在屏幕的可视范围内随机漫游（上下左右都走）
        NSScreen *scr = w.screen ?: NSScreen.mainScreen;
        NSRect vf = scr.visibleFrame;
        NSRect f = w.frame;
        NSTimeInterval nowT = [NSDate timeIntervalSinceReferenceDate];
        // 没目标 / 到达目标 / 超时 → 换一个新的随机目标点
        if (self.walkTarget.x < 0 || nowT >= self.walkRetargetAt ||
            hypot(f.origin.x - self.walkTarget.x, f.origin.y - self.walkTarget.y) < 14) {
            CGFloat m = 10;
            CGFloat tx = vf.origin.x + m + (arc4random_uniform((u_int32_t)(vf.size.width - f.size.width - 2 * m) ?: 1));
            CGFloat ty = vf.origin.y + m + (arc4random_uniform((u_int32_t)(vf.size.height - f.size.height - 2 * m) ?: 1));
            self.walkTarget = NSMakePoint(tx, ty);
            self.walkRetargetAt = nowT + 6.0 + arc4random_uniform(50) / 10.0; // 6~11 秒强制换向
        }
        CGFloat dx = self.walkTarget.x - f.origin.x;
        CGFloat dy = self.walkTarget.y - f.origin.y;
        CGFloat dist = hypot(dx, dy);
        if (dist > 1) {
            CGFloat speed = 3.0;
            f.origin.x += dx / dist * speed;
            f.origin.y += dy / dist * speed;
            if (dx > 0.5) self.mirrored = NO;
            else if (dx < -0.5) self.mirrored = YES;
        }
        // 安全夹回屏幕
        if (f.origin.x < vf.origin.x) f.origin.x = vf.origin.x;
        if (f.origin.y < vf.origin.y) f.origin.y = vf.origin.y;
        if (f.origin.x + f.size.width > vf.origin.x + vf.size.width) f.origin.x = vf.origin.x + vf.size.width - f.size.width;
        if (f.origin.y + f.size.height > vf.origin.y + vf.size.height) f.origin.y = vf.origin.y + vf.size.height - f.size.height;
        [w setFrameOrigin:f.origin];
        if (arc4random_uniform(900) == 0) PlayRandomVoice();
    }

    if (!step) return;
    self.lastFrameTime = now;
    self.frameIdx++;
    if (self.frameIdx >= (NSInteger)frames.count) {
        if (self.oneshot && !self.walkOn) { [self playIdle]; frames = self.clips[self.currentClip]; self.frameIdx = 0; }
        else if (self.oneshot && self.walkOn) {
            NSString *n = self.walkNames.count
                ? self.walkNames[(NSUInteger)arc4random_uniform((u_int32_t)self.walkNames.count)] : nil;
            if (n) [self playClip:n];
            frames = self.clips[self.currentClip];
            self.frameIdx = 0;
        } else self.frameIdx = 0;
    }
    if (self.frameIdx < 0) self.frameIdx = 0;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSArray<NSImage *> *frames = self.clips[self.currentClip];
    if (frames.count == 0) return;
    if (self.frameIdx < 0) self.frameIdx = 0;
    NSImage *img = frames[[[self class] clampIndex:self.frameIdx count:(NSInteger)frames.count]];
    NSSize sz = img.size;
    CGFloat side = sz.width * self.scale, hgt = sz.height * self.scale;

    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    if (self.mirrored) {
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:side yBy:0];
        [t scaleXBy:-1.0 yBy:1.0];
        [t concat];
    }
    [img drawInRect:NSMakeRect(0, 0, side, hgt) fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver fraction:self.opacity
     respectFlipped:YES hints:nil];
    [ctx restoreGraphicsState];
}

- (void)mouseDown:(NSEvent *)e {
    if (e.clickCount >= 2) {
        // 双击: 特别互动（礼物/庆祝类动作 + 语音）
        if (self.walkOn) [self setWalk:NO];
        NSMutableArray *spec = [NSMutableArray array];
        for (NSString *n in [self activeFancyPool])
            if ([n hasPrefix:@"Gift"] || [n hasPrefix:@"Event"]) [spec addObject:n];
        if (spec.count) [self playNamed:spec[(NSUInteger)arc4random_uniform((u_int32_t)spec.count)]];
        PlayRandomVoice();
        return;
    }
    if (self.walkOn) {
        // 散步中点她 = 停下（并顺手把菜单标题同步回来）
        [self setWalk:NO];
    }
    self.dragStartMouse = [NSEvent mouseLocation];
    self.dragStartOrigin = self.hostWindow.frame.origin;
    self.dragActive = NO;
    NSMutableArray *inter = [NSMutableArray array];
    for (NSString *n in self.fancyNames)
        if ([n hasPrefix:@"InteractiveStand"] || [n hasPrefix:@"InteractiveSit"]) [inter addObject:n];
    if (inter.count) [self playNamed:inter[(NSUInteger)arc4random_uniform((u_int32_t)inter.count)]];
    NSString *v = VoiceNamed(@"Sit_Interactive");
    if (!v) v = VoiceNamed(@"Play");
    if (!v) { PlayRandomVoice(); return; }
    NSString *dir = [[[[NSBundle mainBundle] resourceURL] path] stringByAppendingString:@"/Sound/Voice"];
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:v]] error:nil];
    [p play];
    objc_setAssociatedObject(self, "voicePlayer", p, OBJC_ASSOCIATION_RETAIN);
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint m1 = [NSEvent mouseLocation];
    if (!self.dragActive && hypot(m1.x - self.dragStartMouse.x, m1.y - self.dragStartMouse.y) < 4) return;
    self.dragActive = YES;
    [self.hostWindow setFrameOrigin:NSMakePoint(self.dragStartOrigin.x + m1.x - self.dragStartMouse.x,
                                                self.dragStartOrigin.y + m1.y - self.dragStartMouse.y)];
}

- (void)mouseUp:(NSEvent *)e { self.dragActive = NO; }

@end

// ============================ 系统状态气泡 ============================

@interface BubbleView : NSView
@property (nonatomic, copy) NSString *text;
@end
@implementation BubbleView
- (void)setText:(NSString *)t { _text = [t copy]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)r {
    NSRect b = self.bounds;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [[NSColor colorWithWhite:0.12 alpha:0.85] setFill];
    [path fill];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attr = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                           NSForegroundColorAttributeName: [NSColor whiteColor],
                           NSParagraphStyleAttributeName: ps};
    [self.text drawInRect:NSInsetRect(b, 8, 7) withAttributes:attr];
}
@end

// ============================ 找茬小游戏 ============================

@interface GameView : NSView
@property (strong) NSImage *imgA, *imgB;
@property (assign) CGFloat dispScale;
@property (strong) NSArray *spots;
@property (strong) NSMutableArray *found;
@property (assign) NSInteger episode;
@property (copy) NSString *status;
@property (assign) NSTimeInterval startedAt;
- (BOOL)loadEpisode:(NSInteger)n;
@end

@implementation GameView

- (BOOL)loadEpisode:(NSInteger)n {
    NSString *gameDir = [[[[NSBundle mainBundle] resourceURL] path] stringByAppendingPathComponent:@"Game"];
    NSString *dir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Ep%ld", (long)n]];
    self.imgA = [[NSImage alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:@"a.png"]];
    self.imgB = [[NSImage alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:@"b.png"]];
    if (!self.imgA || !self.imgB) return NO;
    NSData *jd = [NSData dataWithContentsOfFile:[gameDir stringByAppendingPathComponent:@"diffs.json"]];
    NSDictionary *all = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    NSDictionary *ep = all[[NSString stringWithFormat:@"Ep%ld", (long)n]] ?: @{};
    self.spots = ep[@"spots"] ?: @[];
    self.found = [NSMutableArray array];
    self.episode = n;
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];
    self.status = [NSString stringWithFormat:@"第 %ld 关 · 已找到 0 / %lu", (long)n, (unsigned long)self.spots.count];
    NSDictionary *best = LoadPrefs()[@"gameBest"] ?: @{};
    NSNumber *b = best[[NSString stringWithFormat:@"Ep%ld", (long)n]];
    if (b) self.status = [self.status stringByAppendingFormat:@" · 最佳 %.1f 秒", b.doubleValue];
    NSSize sz = self.imgA.size;
    // 窗口限制在屏幕可视范围内，避免两张图叠起来超出屏幕
    NSRect vf = (NSScreen.mainScreen ?: NSScreen.screens[0]).visibleFrame;
    CGFloat th = MIN(700.0, (vf.size.height - 100) / 2.0);
    self.dispScale = th / sz.height;
    if ([self window]) {
        NSRect f = [[self window] frame];
        CGFloat wh = MIN(th * 2 + 64, vf.size.height - 40);
        CGFloat ww = MIN(sz.width * self.dispScale + 24, vf.size.width - 40);
        f.size = NSMakeSize(ww, wh);
        // 保证窗口完整落在屏幕内
        f.origin.x = MIN(MAX(f.origin.x, vf.origin.x), vf.origin.x + vf.size.width - ww);
        f.origin.y = MIN(MAX(f.origin.y, vf.origin.y), vf.origin.y + vf.size.height - wh);
        [[self window] setFrame:f display:YES animate:YES];
    }
    [self setNeedsDisplay:YES];
    return YES;
}

// 依据当前视图尺寸计算两张图的布局尺寸（响应式）
- (NSSize)layoutSize {
    NSSize sz = self.imgA.size;
    CGFloat s = MIN((self.bounds.size.width - 24) / sz.width,
                    (self.bounds.size.height - 64) / (2 * sz.height));
    if (s <= 0 || !isfinite(s)) s = 0.1;
    return NSMakeSize(sz.width * s, sz.height * s);
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithCalibratedWhite:0.96 alpha:1] setFill];
    NSRectFill(self.bounds);
    if (!self.imgA) return;
    NSSize sz = self.imgA.size;
    NSSize lay = [self layoutSize];
    CGFloat s = lay.width / sz.width;
    CGFloat w = lay.width, h = lay.height;
    [self.imgA drawInRect:NSMakeRect(12, 12, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.imgB drawInRect:NSMakeRect(12, 24 + h, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];

    NSBezierPath *bp = [NSBezierPath bezierPath];
    bp.lineWidth = 3;
    [[NSColor colorWithCalibratedRed:0.1 green:0.75 blue:0.3 alpha:1] setStroke];
    for (NSDictionary *s2 in self.found) {
        CGFloat x = [s2[@"x"] doubleValue] * s + 12;
        CGFloat y = [s2[@"y"] doubleValue] * s + 12;
        CGFloat r = [s2[@"r"] doubleValue] * s;
        [bp appendBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - r, y - r, 2 * r, 2 * r)]];
        [bp appendBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - r, y + 12 + h - r, 2 * r, 2 * r)]];
    }
    [bp stroke];

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    [self.status drawInRect:NSMakeRect(0, self.bounds.size.height - 26, self.bounds.size.width, 20)
             withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                              NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1],
                              NSParagraphStyleAttributeName: ps}];
}

- (void)mouseDown:(NSEvent *)e {
    if (!self.spots.count || !self.imgA) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSSize lay = [self layoutSize];
    CGFloat w = lay.width, h = lay.height;
    CGFloat s = lay.width / self.imgA.size.width;
    CGFloat iy = -1;
    if (p.x < 12 || p.x > 12 + w) return;
    if (p.y >= 12 && p.y <= 12 + h) iy = p.y - 12;
    else if (p.y >= 24 + h && p.y <= 24 + 2 * h) iy = p.y - 24 - h;
    else return;
    CGFloat ix = (p.x - 12) / s;
    iy = iy / s;

    for (NSDictionary *sp in self.spots) {
        if ([self.found containsObject:sp]) continue;
        CGFloat dx = ix - [sp[@"x"] doubleValue], dy = iy - [sp[@"y"] doubleValue];
        if (hypot(dx, dy) <= [sp[@"r"] doubleValue] + 6) {
            [self.found addObject:sp];
            PlayRandomVoice();
            if (self.found.count == self.spots.count) {
                // 过关: 记录用时与最佳成绩
                double elapsed = [NSDate timeIntervalSinceReferenceDate] - self.startedAt;
                NSMutableDictionary *prefs = LoadPrefs();
                NSMutableDictionary *best = [prefs[@"gameBest"] mutableCopy] ?: [NSMutableDictionary dictionary];
                NSString *ek = [NSString stringWithFormat:@"Ep%ld", (long)self.episode];
                double prev = [best[ek] doubleValue];
                BOOL newRecord = (prev <= 0 || elapsed < prev);
                if (newRecord) best[ek] = @(elapsed);
                prefs[@"gameBest"] = best;
                NSMutableArray *done = [prefs[@"gameDone"] mutableCopy] ?: [NSMutableArray array];
                if (![done containsObject:@(self.episode)]) [done addObject:@(self.episode)];
                prefs[@"gameDone"] = done;
                SavePrefs(prefs);
                self.status = [NSString stringWithFormat:@"第 %ld 关过关！🎉 用时 %.1f 秒%@（累计通关 %lu/20）",
                               (long)self.episode, elapsed,
                               newRecord ? @" 新纪录！" : [NSString stringWithFormat:@" 最佳 %.1f 秒", [best[ek] doubleValue]],
                               (unsigned long)done.count];
            } else
                self.status = [NSString stringWithFormat:@"第 %ld 关 · 已找到 %lu / %lu", (long)self.episode, (unsigned long)self.found.count, (unsigned long)self.spots.count];
            [self setNeedsDisplay:YES];
            return;
        }
    }
}

@end

@interface GameController : NSObject
@property (strong) NSWindow *win;
@property (strong) GameView *view;
- (void)openWindow;
@end
@implementation GameController
- (void)openWindow {
    if (!self.win) {
        self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 900)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                 backing:NSBackingStoreBuffered defer:NO];
        self.win.title = @"天选找茬";
        self.win.releasedWhenClosed = NO;
        self.view = [[GameView alloc] initWithFrame:NSMakeRect(0, 0, 680, 900)];
        self.win.contentView = self.view;
    }
    NSInteger n = self.view.episode > 0 ? self.view.episode + 1 : 1;
    if (n > 21) n = 1;
    NSString *dir = [[[[NSBundle mainBundle] resourceURL] path] stringByAppendingPathComponent:@"Game"];
    for (int tries = 0; tries < 30; tries++) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"Ep%ld/a.png", (long)n]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) break;
        n++;
        if (n > 21) n = 1;
    }
    [self.view loadEpisode:n];
    [self.win center];
    [self.win makeKeyAndOrderFront:nil];
}
@end

// ============================ 猫咪彩蛋 ============================

@interface CatView : NSView
@property (strong) NSArray<NSImage *> *frames;
@property (assign) NSInteger idx;
@end
@implementation CatView
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        NSString *actions = [[[[NSBundle mainBundle] resourceURL] path] stringByAppendingPathComponent:@"Actions"];
        NSMutableArray *fs = [NSMutableArray array];
        for (NSString *g in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:actions error:nil]) {
            if (![g hasPrefix:@"WAM_"] || ![g hasSuffix:@".frames"]) continue;
            NSString *dir = [actions stringByAppendingPathComponent:g];
            for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
                if ([f hasSuffix:@".png"]) {
                    NSImage *img = [[NSImage alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
                    if (img) [fs addObject:img];
                }
        }
        self.frames = fs;
        self.idx = (NSInteger)arc4random_uniform((u_int32_t)MAX(1, fs.count));
        NSTimer *t = [NSTimer timerWithTimeInterval:1.0 / 12.0 target:self selector:@selector(step) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (void)step {
    if (!self.frames.count) return;
    self.idx = (self.idx + 1) % (NSInteger)self.frames.count;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)r {
    if (!self.frames.count) return;
    [self.frames[self.idx] drawInRect:self.bounds fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
@end

@interface CatController : NSObject
@property (strong) NSWindow *win;
- (void)appearNear:(NSRect)mascotFrame;
@end
@implementation CatController
- (void)appearNear:(NSRect)mf {
    if (self.win) return; // 猫已经在场
    CGFloat side = 220;
    NSScreen *scr = NSScreen.mainScreen;
    NSRect vf = scr.visibleFrame;
    NSPoint origin = NSMakePoint(mf.origin.x - side / 2.0, mf.origin.y);
    origin.x = MIN(MAX(origin.x, vf.origin.x), vf.origin.x + vf.size.width - side);
    origin.y = MIN(MAX(origin.y, vf.origin.y), vf.origin.y + vf.size.height - side);
    self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, side, side)
                                           styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
    self.win.opaque = NO;
    self.win.backgroundColor = [NSColor clearColor];
    self.win.hasShadow = NO;
    self.win.level = NSFloatingWindowLevel;
    self.win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    self.win.contentView = [[CatView alloc] initWithFrame:NSMakeRect(0, 0, side, side)];
    [self.win makeKeyAndOrderFront:nil];
    // 缓慢向左溜达，13 秒后消失
    __weak typeof(self) wself = self;
    NSTimer *mover = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(wself) s = wself;
        if (!s || !s.win) { [t invalidate]; return; }
        NSRect f = s.win.frame;
        f.origin.x -= 0.6;
        [s.win setFrameOrigin:f.origin];
    }];
    [[NSRunLoop mainRunLoop] addTimer:mover forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(13 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [wself dismiss];
    });
}
- (void)dismiss {
    [self.win orderOut:nil];
    self.win = nil;
}
@end

// ============================ AI 对话 ============================

static NSDictionary *LoadChatConfig(void) {
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TXMascot/config.plist"];
    return [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
}

@interface Rule : NSObject
- (instancetype)initWithKey:(NSString *)k replies:(NSArray *)r;
@property (readonly) NSString *key;
@property (readonly) NSArray *replies;
@end
@implementation Rule {
    NSString *_k;
    NSArray *_r;
}
- (instancetype)initWithKey:(NSString *)k replies:(NSArray *)r {
    self = [super init];
    if (self) { _k = k; _r = r; }
    return self;
}
- (NSString *)key { return _k; }
- (NSArray *)replies { return _r; }
@end

static NSArray<NSString *> *OfflineReply(NSString *input) {
    input = input.lowercaseString;
    NSArray<Rule *> *rules = @[
        [[Rule alloc] initWithKey:@"你好|hi|hello|在吗" replies:@[@"你好呀！我是天选姬～(≧▽≦)", @"在的在的！叫我干嘛？"]],
        [[Rule alloc] initWithKey:@"名字|你是谁" replies:@[@"我是天选姬呀，华硕天选的看板娘！现在寄住在你的 Mac 里啦～", @"我叫天选姬！你的专属桌面小助手！"]],
        [[Rule alloc] initWithKey:@"天气" replies:@[@"Mac 上看不到天气啦，不过你的心情必须是大晴天！☀️", @"抬头看看窗外嘛～"]],
        [[Rule alloc] initWithKey:@"累|加班|摸鱼" replies:@[@"辛苦啦！记得休息一下，我陪你摸鱼～", @"劳逸结合！要不要看我跳个舞？"]],
        [[Rule alloc] initWithKey:@"帅|美|好看|可爱" replies:@[@"哎呀，被你发现了，人家本来就可爱嘛～(*/ω＼*)", @"你眼光真好！"]],
        [[Rule alloc] initWithKey:@"华硕|天选|asus" replies:@[@"天选，本命机！TX BRO 走起！", @"天选姬可是天选系列的门面担当哦！"]],
        [[Rule alloc] initWithKey:@"谢谢|感谢" replies:@[@"不客气啦～", @"嘿嘿，小意思！"]],
        [[Rule alloc] initWithKey:@"再见|拜拜|晚安" replies:@[@"拜拜～记得回来看我哦！", @"晚安，做个好梦～"]],
        [[Rule alloc] initWithKey:@"笑话|讲个" replies:@[@"为什么程序员分不清万圣节和圣诞节？因为 OCT 31 == DEC 25 呀！", @"我给自己取了个外号：编译通过侠。因为每次编译通过都是我救了主人。"]],
    ];
    for (Rule *r in rules) {
        if ([input rangeOfString:r.key options:NSRegularExpressionSearch].location != NSNotFound)
            return r.replies;
    }
    return @[@"嗯嗯，我在听～然后呢？", @"这个问题有点深奥，容我想想…诶嘿，没想到！",
             @"要看看我的才艺表演吗？右键点我就有哦！", @"Mac 版的我还是个宝宝，好多话还不会说呢～",
             @"今天也要元气满满哦！", @"叮！检测到主人上线啦～"];
}

@interface ChatController : NSObject
@property (strong) NSWindow *win;
@property (strong) NSTextView *log;
@property (strong) NSTextField *input;
@property (strong) NSMutableArray<NSDictionary *> *history;
- (void)showWindow;
@end
@implementation ChatController

- (void)showWindow {
    if (!self.win) {
        self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 470)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                 backing:NSBackingStoreBuffered defer:NO];
        self.win.title = @"和天选姬聊天";
        self.win.releasedWhenClosed = NO;
        self.history = [NSMutableArray array];

        NSTextView *log = [[NSTextView alloc] initWithFrame:NSZeroRect];
        log.editable = NO;
        log.drawsBackground = NO;
        log.textContainerInset = NSMakeSize(8, 8);
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 44, 360, 384)];
        sv.hasVerticalScroller = YES;
        sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        sv.documentView = log;
        self.log = log;

        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 8, 258, 28)];
        input.placeholderString = @"说点什么…";
        input.target = self;
        input.action = @selector(send:);
        input.autoresizingMask = NSViewWidthSizable;
        self.input = input;

        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(274, 8, 78, 28)];
        btn.title = @"发送";
        btn.bezelStyle = NSBezelStyleRounded;
        btn.target = self;
        btn.action = @selector(send:);
        btn.autoresizingMask = NSViewMinXMargin;

        NSButton *cfgBtn = [[NSButton alloc] initWithFrame:NSMakeRect(8, 418, 110, 26)];
        cfgBtn.title = @"AI 接口设置";
        cfgBtn.bezelStyle = NSBezelStyleRounded;
        cfgBtn.target = self;
        cfgBtn.action = @selector(configAI:);

        [self.win.contentView addSubview:sv];
        [self.win.contentView addSubview:input];
        [self.win.contentView addSubview:btn];
        [self.win.contentView addSubview:cfgBtn];

        [self appendBubble:@"系统" text:@"我是天选姬～跟我聊天吧！\n默认是离线台词模式；点左下角「AI 接口设置」可接入任意 OpenAI 兼容接口（DeepSeek/智谱/通义…）变成真 AI。" color:[NSColor colorWithCalibratedRed:0.4 green:0.45 blue:0.55 alpha:1]];
    }
    [self.win center];
    [self.win makeKeyAndOrderFront:nil];
}

- (void)appendBubble:(NSString *)who text:(NSString *)text color:(NSColor *)color {
    NSDictionary *attr = @{NSFontAttributeName: [NSFont systemFontOfSize:13],
                           NSForegroundColorAttributeName: color};
    NSTextStorage *ts = self.log.textStorage;
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@: %@\n\n", who, text] attributes:attr]];
    [self.log scrollRangeToVisible:NSMakeRange(self.log.string.length, 0)];
}

- (void)send:(id)sender {
    NSString *text = self.input.stringValue;
    if (!text.length) return;
    self.input.stringValue = @"";
    [self appendBubble:@"你" text:text color:[NSColor blackColor]];
    [self.history addObject:@{@"role": @"user", @"content": text}];
    [self replyTo:text];
}

- (void)replyTo:(NSString *)text {
    NSDictionary *cfg = LoadChatConfig();
    NSString *ep = cfg[@"apiEndpoint"], *key = cfg[@"apiKey"], *model = cfg[@"model"];
    if (!ep.length || !key.length || !model.length) {
        NSArray *pool = OfflineReply(text);
        NSString *reply = pool[(NSUInteger)arc4random_uniform((u_int32_t)pool.count)];
        [self performSelector:@selector(showReply:) withObject:reply afterDelay:0.6];
        return;
    }
    NSMutableArray *msgs = [NSMutableArray array];
    [msgs addObject:@{@"role": @"system", @"content": @"你是华硕天选姬，一个可爱的二次元看板娘桌宠，现在住在用户的 Mac 上。用简短、活泼、带一点撒娇语气的简体中文回复，不超过60字。"}];
    [msgs addObjectsFromArray:self.history];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ep]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 30;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"model": model, @"messages": msgs} options:0 error:nil];
    __weak typeof(self) wself = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(wself) s = wself;
        if (!s) return;
        NSString *reply = nil;
        if (!err && data) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            reply = j[@"choices"][0][@"message"][@"content"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (reply.length) [s showReply:reply];
            else [s showReply:@"呜…AI 接口连接失败了，检查下设置里的地址和密钥？"];
        });
    }] resume];
}

- (void)showReply:(NSString *)reply {
    [self appendBubble:@"天选姬" text:reply color:[NSColor colorWithCalibratedRed:0.85 green:0.2 blue:0.5 alpha:1]];
    [self.history addObject:@{@"role": @"assistant", @"content": reply}];
    if (self.history.count > 20) [self.history removeObjectsInRange:NSMakeRange(0, 2)];
    PlayRandomVoice();
}

- (void)configAI:(id)sender {
    NSDictionary *cfg = LoadChatConfig();
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"AI 接口设置（OpenAI 兼容）";
    alert.informativeText = @"例如 DeepSeek / 智谱 / 通义。三项都填了才会启用真 AI，否则用离线台词。";
    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
    NSTextField *f1 = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 74, 300, 24)];
    f1.placeholderString = @"接口地址 https://api.deepseek.com/v1/chat/completions";
    f1.stringValue = cfg[@"apiEndpoint"] ?: @"";
    NSTextField *f2 = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 40, 300, 24)];
    f2.placeholderString = @"API Key";
    f2.stringValue = cfg[@"apiKey"] ?: @"";
    NSTextField *f3 = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 6, 300, 24)];
    f3.placeholderString = @"模型名 如 deepseek-chat";
    f3.stringValue = cfg[@"model"] ?: @"";
    [acc addSubview:f1]; [acc addSubview:f2]; [acc addSubview:f3];
    alert.accessoryView = acc;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TXMascot"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (f1.stringValue.length) d[@"apiEndpoint"] = f1.stringValue;
        if (f2.stringValue.length) d[@"apiKey"] = f2.stringValue;
        if (f3.stringValue.length) d[@"model"] = f3.stringValue;
        [d writeToFile:[dir stringByAppendingPathComponent:@"config.plist"] atomically:YES];
        [self appendBubble:@"系统" text:@"配置已保存～再发消息试试！" color:[NSColor colorWithCalibratedRed:0.4 green:0.45 blue:0.55 alpha:1]];
    }
}
@end

// ============================ 主控制器 ============================

@class AppDelegate;
static OSStatus TXHotKeyHandler(EventHandlerCallRef inRef, EventRef ev, void *ud);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) MascotView *mascot;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSWindow *bubbleWin;
@property (strong) BubbleView *bubble;
@property (strong) NSTimer *sysTimer;
@property (assign) BOOL bubbleOn;
@property (strong) GameController *game;
@property (strong) ChatController *chat;
@property (strong) CatController *cat;
@property (strong) NSMenuItem *walkMenuItem;
@property (strong) NSMenuItem *autoStartItem;
@property (strong) NSTimer *reminderTimer;
@property (strong) NSWindow *speechWin;
@property (strong) BubbleView *speech;
@end
@implementation AppDelegate

static OSStatus TXHotKeyHandler(EventHandlerCallRef inRef, EventRef ev, void *ud) {
    AppDelegate *d = (__bridge AppDelegate *)ud;
    dispatch_async(dispatch_get_main_queue(), ^{ [d openChat:nil]; });
    return noErr;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 300)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.opaque = NO;
    self.window.backgroundColor = [NSColor clearColor];
    self.window.hasShadow = NO;
    self.window.level = NSFloatingWindowLevel;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.window.releasedWhenClosed = NO;

    self.mascot = [[MascotView alloc] init];
    self.mascot.hostWindow = self.window;
    self.window.contentView = self.mascot;

    NSRect vf = NSScreen.mainScreen.visibleFrame;
    [self.window setFrameOrigin:NSMakePoint(vf.origin.x + vf.size.width - 380, vf.origin.y + 60)];
    [self.window makeKeyAndOrderFront:nil];

    [self buildMenu];

    self.sysTimer = [NSTimer timerWithTimeInterval:3.0 target:self selector:@selector(updateSys:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.sysTimer forMode:NSRunLoopCommonModes];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(walkChanged:) name:@"TXWalkChanged" object:nil];

    // 恢复上次的窗口位置/大小/不透明度/服装等设置
    [self restorePrefs];
    // 定期持久化状态（拖动/切设置 5 秒内落盘）
    NSTimer *saveT = [NSTimer timerWithTimeInterval:5.0 target:self selector:@selector(saveState) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:saveT forMode:NSRunLoopCommonModes];
    NSLog(@"[TX] save timer armed");
    // 全局快捷键 ⌥⌘C 呼出 AI 对话
    [self installHotKeys];
    // 猫咪彩蛋: 每 12 分钟有四成概率来一次
    [self scheduleCat];

    // 调试钩子: TXAUTOACT=1 每 6 秒随机表演一次
    if (getenv("TXAUTOACT")) {
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 6 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(t, ^{ [self.mascot playFancy]; });
        dispatch_resume(t);
    }
    // 调试钩子: TXAUTOWALK=1 启动时自动进入散步模式
    if (getenv("TXAUTOWALK")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.mascot setWalk:YES];
        });
    }
}

- (void)updateSys:(NSTimer *)t {
    if (!self.bubbleOn) return;
    double cpu = SysCPULoad(), ram = SysRAMUsed();
    NSString *line = @"";
    if (cpu > 80) line = @"  CPU 好烫！(>_<)";
    else if (ram > 85) line = @"  内存有点挤…";
    self.bubble.text = [NSString stringWithFormat:@"CPU %.0f%%   内存 %.0f%%%@\n", cpu, ram, line];
    [self placeBubble];
}

- (void)placeBubble {
    if (!self.bubbleWin) return;
    NSRect pf = self.window.frame;
    NSRect bf = self.bubbleWin.frame;
    [self.bubbleWin setFrameOrigin:NSMakePoint(pf.origin.x + (pf.size.width - bf.size.width) / 2,
                                               pf.origin.y + pf.size.height + 6)];
}

- (void)toggleBubble {
    self.bubbleOn = !self.bubbleOn;
    if (self.bubbleOn) {
        if (!self.bubbleWin) {
            self.bubbleWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 230, 54)
                                                         styleMask:NSWindowStyleMaskBorderless
                                                           backing:NSBackingStoreBuffered defer:NO];
            self.bubbleWin.opaque = NO;
            self.bubbleWin.backgroundColor = [NSColor clearColor];
            self.bubbleWin.hasShadow = NO;
            self.bubbleWin.level = NSFloatingWindowLevel + 1;
            self.bubbleWin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
            self.bubble = [[BubbleView alloc] initWithFrame:NSMakeRect(0, 0, 230, 54)];
            self.bubbleWin.contentView = self.bubble;
            self.bubble.text = @"CPU --%   内存 --%";
        }
        [self.bubbleWin orderFrontRegardless];
        [self updateSys:nil];
    } else {
        [self.bubbleWin orderOut:nil];
    }
}

// ---------- 记忆 / 自启动 / 提醒 / 语音 / 彩蛋 ----------

- (void)restorePrefs {
    NSDictionary *p = LoadPrefs();
    if ([p[@"scale"] doubleValue] > 0) self.mascot.scale = [p[@"scale"] doubleValue];
    if ([p[@"opacity"] doubleValue] > 0) self.mascot.opacity = [p[@"opacity"] doubleValue];
    self.mascot.suitMode = [p[@"suitMode"] boolValue];
    NSPoint pos = NSMakePoint([p[@"posX"] doubleValue], [p[@"posY"] doubleValue]);
    if (pos.x != 0 || pos.y != 0) {
        BOOL onScreen = NO;
        for (NSScreen *s in NSScreen.screens)
            if (NSPointInRect(pos, s.frame)) { onScreen = YES; break; }
        if (onScreen) [self.window setFrameOrigin:pos];
    }
    if ([p[@"bubbleOn"] boolValue]) {
        self.bubbleOn = NO;
        [self toggleBubble];
    }
}

- (void)saveState {
    NSMutableDictionary *p = LoadPrefs();
    p[@"posX"] = @(self.window.frame.origin.x);
    p[@"posY"] = @(self.window.frame.origin.y);
    p[@"scale"] = @(self.mascot.scale);
    p[@"opacity"] = @(self.mascot.opacity);
    p[@"bubbleOn"] = @(self.bubbleOn);
    p[@"suitMode"] = @(self.mascot.suitMode);
    SavePrefs(p);
}

- (void)installHotKeys {
    EventHotKeyID hk; hk.signature = 'txmc'; hk.id = 1;
    RegisterEventHotKey(kVK_ANSI_C, cmdKey | optionKey, hk, GetApplicationEventTarget(), 0, NULL);
    EventTypeSpec ts = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(NewEventHandlerUPP(TXHotKeyHandler), 1, &ts, (__bridge void *)self, NULL);
}

- (void)scheduleCat {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                              12 * 60 * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{
        if (arc4random_uniform(100) >= 45) return;
        if (!self.cat) self.cat = [CatController new];
        [self.cat appearNear:self.window.frame];
    });
    dispatch_resume(t);
}

- (void)showSpeech:(NSString *)text {
    if (!self.speechWin) {
        self.speechWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 54)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered defer:NO];
        self.speechWin.opaque = NO;
        self.speechWin.backgroundColor = [NSColor clearColor];
        self.speechWin.hasShadow = NO;
        self.speechWin.level = NSFloatingWindowLevel + 2;
        self.speechWin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
        self.speech = [[BubbleView alloc] initWithFrame:NSMakeRect(0, 0, 320, 54)];
        self.speechWin.contentView = self.speech;
    }
    self.speech.text = text;
    NSRect pf = self.window.frame;
    NSRect bf = self.speechWin.frame;
    [self.speechWin setFrameOrigin:NSMakePoint(pf.origin.x + (pf.size.width - bf.size.width) / 2,
                                               pf.origin.y + pf.size.height + 6)];
    [self.speechWin orderFrontRegardless];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideSpeech) object:nil];
    [self performSelector:@selector(hideSpeech) withObject:nil afterDelay:6.0];
}
- (void)hideSpeech { [self.speechWin orderOut:nil]; }

- (void)setReminder:(NSMenuItem *)s {
    double mins = [s.representedObject doubleValue];
    [self.reminderTimer invalidate]; self.reminderTimer = nil;
    if (mins > 0) {
        self.reminderTimer = [NSTimer timerWithTimeInterval:mins * 60.0 target:self selector:@selector(reminderFire) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.reminderTimer forMode:NSRunLoopCommonModes];
        [self showSpeech:[NSString stringWithFormat:@"好！每 %.0f 分钟喊你休息一次～", mins]];
    } else {
        [self showSpeech:@"提醒已关闭，累了记得自己休息哦～"];
    }
}
- (void)reminderFire {
    [self.mascot playFancy];
    PlayRandomVoice();
    [self showSpeech:@"休息一下吧！护护眼、伸个懒腰～ (๑•̀ㅂ•́)✧"];
}

- (BOOL)isAutoStart {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return NO;
}
- (void)toggleAutoStart:(NSMenuItem *)s {
    BOOL on = ![self isAutoStart];
    NSError *err = nil;
    if (@available(macOS 13.0, *)) {
        if (on) [SMAppService.mainAppService registerAndReturnError:&err];
        else [SMAppService.mainAppService unregisterAndReturnError:&err];
    }
    if (err) [self showSpeech:[NSString stringWithFormat:@"设置失败：%@", err.localizedDescription]];
    else [self showSpeech:on ? @"以后开机我就自动来啦～" : @"好啦，开机不再自动启动。"];
    self.autoStartItem.title = [self isAutoStart] ? @"开机自启动：开" : @"开机自启动：关";
}

- (void)summonCat:(id)sender {
    if (!self.cat) self.cat = [CatController new];
    [self.cat appearNear:self.window.frame];
}

- (void)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *walk = [[NSMenuItem alloc] initWithTitle:@"散步模式：关" action:@selector(toggleWalk:) keyEquivalent:@"w"];
    walk.target = self;
    [menu addItem:walk];

    NSMenuItem *sys = [[NSMenuItem alloc] initWithTitle:@"系统状态：关" action:@selector(toggleSys:) keyEquivalent:@"s"];
    sys.target = self;
    [menu addItem:sys];

    NSMenuItem *chat = [[NSMenuItem alloc] initWithTitle:@"AI 对话…" action:@selector(openChat:) keyEquivalent:@"c"];
    chat.target = self;
    [menu addItem:chat];

    NSMenuItem *game = [[NSMenuItem alloc] initWithTitle:@"找茬小游戏…" action:@selector(openGame:) keyEquivalent:@"g"];
    game.target = self;
    [menu addItem:game];

    NSMenuItem *wallpaper = [[NSMenuItem alloc] initWithTitle:@"设置壁纸…" action:@selector(setWallpaper:) keyEquivalent:@""];
    wallpaper.target = self;
    [menu addItem:wallpaper];

    NSMenuItem *fancy = [[NSMenuItem alloc] initWithTitle:@"看表演（随机动作）" action:@selector(playFancy:) keyEquivalent:@"p"];
    fancy.target = self;
    [menu addItem:fancy];

    // 换装
    NSMenu *suitMenu = [[NSMenu alloc] init];
    NSMenuItem *suitShow = [[NSMenuItem alloc] initWithTitle:@"随机换装动作" action:@selector(playSuitShow:) keyEquivalent:@""];
    suitShow.target = self;
    [suitMenu addItem:suitShow];
    [suitMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *s0 = [[NSMenuItem alloc] initWithTitle:@"原版服装" action:@selector(setSuitMode:) keyEquivalent:@""];
    s0.representedObject = @NO; s0.target = self;
    s0.state = self.mascot.suitMode ? NSControlStateValueOff : NSControlStateValueOn;
    [suitMenu addItem:s0];
    NSMenuItem *s1 = [[NSMenuItem alloc] initWithTitle:@"黑白新装" action:@selector(setSuitMode:) keyEquivalent:@""];
    s1.representedObject = @YES; s1.target = self;
    s1.state = self.mascot.suitMode ? NSControlStateValueOn : NSControlStateValueOff;
    [suitMenu addItem:s1];
    NSMenuItem *suitItem = [[NSMenuItem alloc] initWithTitle:@"换装" action:nil keyEquivalent:@""];
    suitItem.submenu = suitMenu;
    [menu addItem:suitItem];

    NSMenuItem *catItem = [[NSMenuItem alloc] initWithTitle:@"召唤小猫 🐾" action:@selector(summonCat:) keyEquivalent:@""];
    catItem.target = self;
    [menu addItem:catItem];

    // 休息提醒
    NSMenu *remMenu = [[NSMenu alloc] init];
    for (NSDictionary *d in @[@{@"t": @"每 25 分钟（番茄钟）", @"m": @25},
                              @{@"t": @"每 45 分钟", @"m": @45},
                              @{@"t": @"每 60 分钟", @"m": @60},
                              @{@"t": @"关闭提醒", @"m": @0}]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:d[@"t"] action:@selector(setReminder:) keyEquivalent:@""];
        it.representedObject = d[@"m"];
        it.target = self;
        [remMenu addItem:it];
    }
    NSMenuItem *remItem = [[NSMenuItem alloc] initWithTitle:@"休息提醒" action:nil keyEquivalent:@""];
    remItem.submenu = remMenu;
    [menu addItem:remItem];

    NSMenuItem *autoStart = [[NSMenuItem alloc] initWithTitle:[self isAutoStart] ? @"开机自启动：开" : @"开机自启动：关"
                                                              action:@selector(toggleAutoStart:) keyEquivalent:@""];
    autoStart.target = self;
    [menu addItem:autoStart];
    self.autoStartItem = autoStart;

    NSMenu *sizeMenu = [[NSMenu alloc] init];
    for (NSDictionary *d in @[@{@"t": @"特小 50%", @"s": @0.5},
                              @{@"t": @"小 70%", @"s": @0.7},
                              @{@"t": @"中 100%", @"s": @1.0},
                              @{@"t": @"大 130%", @"s": @1.3}]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:d[@"t"] action:@selector(setSize:) keyEquivalent:@""];
        it.representedObject = d[@"s"];
        it.target = self;
        [sizeMenu addItem:it];
    }
    NSMenuItem *sizeItem = [[NSMenuItem alloc] initWithTitle:@"大小" action:nil keyEquivalent:@""];
    sizeItem.submenu = sizeMenu;
    [menu addItem:sizeItem];

    NSMenu *opMenu = [[NSMenu alloc] init];
    for (NSDictionary *d in @[@{@"t": @"25%", @"o": @0.25}, @{@"t": @"50%", @"o": @0.5},
                              @{@"t": @"75%", @"o": @0.75}, @{@"t": @"100%", @"o": @1.0}]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:d[@"t"] action:@selector(setOpacity:) keyEquivalent:@""];
        it.representedObject = d[@"o"];
        it.target = self;
        [opMenu addItem:it];
    }
    NSMenuItem *opItem = [[NSMenuItem alloc] initWithTitle:@"不透明度" action:nil keyEquivalent:@""];
    opItem.submenu = opMenu;
    [menu addItem:opItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.mascot.menu = menu;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🐱";
    self.statusItem.menu = menu;
}

- (void)toggleWalk:(NSMenuItem *)s {
    BOOL on = !self.mascot.walkOn;
    [self.mascot setWalk:on];
    s.title = on ? @"散步模式：开" : @"散步模式：关";
}

- (void)walkChanged:(NSNotification *)n {
    BOOL on = [n.object boolValue];
    self.walkMenuItem.title = on ? @"散步模式：开" : @"散步模式：关";
}

- (void)toggleSys:(NSMenuItem *)s {
    [self toggleBubble];
    s.title = self.bubbleOn ? @"系统状态：开" : @"系统状态：关";
}

- (void)openChat:(id)sender {
    if (!self.chat) self.chat = [ChatController new];
    [self.chat showWindow];
}

- (void)openGame:(id)sender {
    if (!self.game) self.game = [GameController new];
    [self.game openWindow];
}

- (void)setWallpaper:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择壁纸图片";
    panel.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tiff"];
    panel.canChooseDirectories = NO;
    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        [NSWorkspace.sharedWorkspace setDesktopImageURL:panel.URL
                                               forScreen:NSScreen.mainScreen
                                                 options:@{NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown)}
                                                  error:nil];
    }
}

- (void)playFancy:(id)s { [self.mascot playFancy]; }
- (void)playSuitShow:(id)s { [self.mascot playSuitShow]; }
- (void)setSuitMode:(NSMenuItem *)s {
    self.mascot.suitMode = [s.representedObject boolValue];
    [self.mascot applyCostumeChange];
    for (NSMenuItem *it in s.menu.itemArray)
        it.state = ([it.representedObject boolValue] == self.mascot.suitMode) ? NSControlStateValueOn : NSControlStateValueOff;
    [self saveState];
}
- (void)setSize:(NSMenuItem *)s { self.mascot.scale = [s.representedObject doubleValue]; }
- (void)setOpacity:(NSMenuItem *)s { self.mascot.opacity = [s.representedObject doubleValue]; }
- (void)quit:(id)s { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)n {
    [self saveState];
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
