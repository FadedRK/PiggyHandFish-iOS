#import "PFLogger.h"

void PFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[PiggyHandFish] %@\n", message];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    @synchronized (PFLog) {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}
