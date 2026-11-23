#import <Foundation/Foundation.h>
#import <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// Runs when dyld maps this bundle, before any Swift initializer. If this line
// never appears, legacyScreenSaver did not load the binary (architecture,
// signature, or a missing Swift library).

static void greyline_append(const char *path, const char *message) {
    FILE *file = fopen(path, "a");
    if (!file) {
        return;
    }
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S", &parts);
    fprintf(file, "%s %s\n", stamp, message);
    fclose(file);
}

static void greyline_note(const char *message) {
    os_log_t log = os_log_create("com.greylinehub.screensaver", "load");
    os_log(log, "GreylineHub: %{public}s", message);
    os_log(OS_LOG_DEFAULT, "GreylineHub: %{public}s", message);
    NSString *container = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:container
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    greyline_append([[container stringByAppendingPathComponent:@"GreylineHub-saver.log"] fileSystemRepresentation], message);
    const char *home = getenv("HOME");
    char path[1024];
    greyline_append("/tmp/GreylineHub-saver.log", message);
    if (home && home[0]) {
        snprintf(path, sizeof(path), "%s/Library/Logs/GreylineHub-saver.log", home);
        greyline_append(path, message);
        snprintf(path, sizeof(path),
                 "%s/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/GreylineHub-saver.log",
                 home);
        greyline_append(path, message);
    }
}

__attribute__((constructor))
static void greyline_hub_constructor(void) {
    greyline_note("constructor: GreylineHub image mapped");
}

@interface GreylineHubLoadProbe : NSObject
@end

@implementation GreylineHubLoadProbe

+ (void)load {
    Class principal = NSClassFromString(@"GreylineHubView");
    if (principal) {
        greyline_note("load: NSClassFromString(GreylineHubView) found");
    } else {
        greyline_note("load: NSClassFromString(GreylineHubView) not registered yet");
    }
}

@end
