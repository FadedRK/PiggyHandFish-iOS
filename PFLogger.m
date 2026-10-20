#import "PFLogger.h"
#import <dispatch/dispatch.h>

static NSObject *PFLoggerLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

void PFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[PiggyHandFish] %@\n", message];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    // Synchronize on a real Objective-C object. A C function pointer is not a valid
    // @synchronized lock and caused the first CI build to fail.
    @synchronized (PFLoggerLock()) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            BOOL created = [[NSFileManager defaultManager] createFileAtPath:path
                                                                    contents:nil
                                                                  attributes:nil];
            if (!created) {
                NSLog(@"[PiggyHandFish] Could not create log file at %@", path);
                return;
            }
            handle = [NSFileHandle fileHandleForWritingAtPath:path];
        }

        if (!handle) {
            NSLog(@"[PiggyHandFish] Could not open log file at %@", path);
            return;
        }

        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (NSException *exception) {
            NSLog(@"[PiggyHandFish] Log write failed: %@", exception.reason);
        } @finally {
            [handle closeFile];
        }
    }
}
