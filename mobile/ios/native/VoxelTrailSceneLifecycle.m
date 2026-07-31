// UIScene compatibility layer for the LÖVE 11.5 / SDL 2.28 iOS runner.
//
// iOS/iPadOS 27 requires apps built with the 27 SDK to adopt UIScene. SDL
// 2.28 predates that requirement and otherwise traps before Lua can start.
// This adapter preserves SDL's app delegate and run loop while delaying its
// main callback until UIKit has connected a window scene. The UIWindow
// initializer shim attaches SDL's existing UIWindow subclass to that scene.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SDLUIKitDelegate : NSObject <UIApplicationDelegate>
+ (NSString *)getAppDelegateClassName;
- (void)postFinishLaunch;
@end

extern void SDL_OnApplicationDidBecomeActive(void);
extern void SDL_OnApplicationWillResignActive(void);
extern void SDL_OnApplicationDidEnterBackground(void);
extern void SDL_OnApplicationWillEnterForeground(void);

static __weak UIWindowScene *VoxelTrailActiveScene;

@interface VoxelTrailAppDelegate : SDLUIKitDelegate
@property(nonatomic) BOOL voxelTrailWaitingForScene;
- (void)voxelTrailStartSDLIfReady;
@end

@interface VoxelTrailSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation SDLUIKitDelegate (VoxelTrailSceneLifecycle)

+ (NSString *)getAppDelegateClassName
{
    return @"VoxelTrailAppDelegate";
}

@end

@implementation VoxelTrailAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
        configurationForConnectingSceneSession:(UISceneSession *)session
        options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0))
{
    UISceneConfiguration *configuration =
        [[UISceneConfiguration alloc] initWithName:@"VoxelTrail Default"
                                      sessionRole:session.role];
    configuration.delegateClass = [VoxelTrailSceneDelegate class];
    return configuration;
}

- (void)postFinishLaunch
{
    if (@available(iOS 13.0, *)) {
        if (VoxelTrailActiveScene == nil) {
            self.voxelTrailWaitingForScene = YES;
            return;
        }
    }
    self.voxelTrailWaitingForScene = NO;
    [super postFinishLaunch];
}

- (void)voxelTrailStartSDLIfReady
{
    if (self.voxelTrailWaitingForScene && VoxelTrailActiveScene != nil) {
        [self postFinishLaunch];
    }
}

@end

@implementation VoxelTrailSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
        options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    VoxelTrailActiveScene = (UIWindowScene *)scene;
    VoxelTrailAppDelegate *delegate =
        (VoxelTrailAppDelegate *)UIApplication.sharedApplication.delegate;
    [delegate voxelTrailStartSDLIfReady];
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
    SDL_OnApplicationDidBecomeActive();
    Class picker = NSClassFromString(@"GRPickerBridge");
    if ([picker respondsToSelector:@selector(sweepInbox)]) {
        [picker performSelector:@selector(sweepInbox)];
    }
}

- (void)sceneWillResignActive:(UIScene *)scene
{
    SDL_OnApplicationWillResignActive();
}

- (void)sceneWillEnterForeground:(UIScene *)scene
{
    SDL_OnApplicationWillEnterForeground();
}

- (void)sceneDidEnterBackground:(UIScene *)scene
{
    SDL_OnApplicationDidEnterBackground();
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
    if (scene == VoxelTrailActiveScene) {
        VoxelTrailActiveScene = nil;
    }
}

@end

@implementation UIWindow (VoxelTrailSceneLifecycle)

+ (void)load
{
    Method original = class_getInstanceMethod(self, @selector(initWithFrame:));
    Method replacement =
        class_getInstanceMethod(self, @selector(voxelTrail_initWithFrame:));
    method_exchangeImplementations(original, replacement);
}

- (instancetype)voxelTrail_initWithFrame:(CGRect)frame
{
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = VoxelTrailActiveScene;
        if (scene != nil) {
            return [self initWithWindowScene:scene];
        }
    }
    return [self voxelTrail_initWithFrame:frame];
}

@end
