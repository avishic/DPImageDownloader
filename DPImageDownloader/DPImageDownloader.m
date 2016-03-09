#import  "DPImageDownloader.h"
#import  "DPImageDownloaderCache.h"
#import  <CommonCrypto/CommonDigest.h>
#include <time.h>

#define kMaxMemCacheItems 100

//@avishic: Making sure always on main thread - so no @synchronized required -> not blocking main thread
static void dispatch_sync_main_thread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

@interface DPImageDownloader ()
{
    dispatch_queue_t     _storageQueue;
    NSMutableDictionary* _memoryCache;
}
@end


@implementation DPImageDownloader

#pragma mark - Singleton Pattern

+ (instancetype)sharedInstance
{
    static id downloader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        downloader = [[[self class] alloc] initInstance];
    });
    return downloader;
}

- (instancetype)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initInstance
{
    self = [super init];
    if (self) {
        _storageQueue = dispatch_queue_create("org.dnpp73.library.DPImageDownloader.storage", DISPATCH_QUEUE_SERIAL);
        _memoryCache = [NSMutableDictionary dictionaryWithCapacity:50];
        
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(memoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

#pragma mark - Main Methods

- (DPImageType*)getImageWithURL:(NSString*)url
               useOnMemoryCache:(BOOL)useOnMemoryCache
                       lifeTime:(NSUInteger)lifeTime
                     completion:(DPImageDownloaderCompleteBlock)completion
{
    return [self getImageWithURL:url useOnMemoryCache:useOnMemoryCache lifeTime:lifeTime completionQueue:dispatch_get_main_queue() completion:completion];
}

-  (DPImageType*)getImageWithURL:(NSString*)url
                useOnMemoryCache:(BOOL)useOnMemoryCache
                        lifeTime:(NSUInteger)lifeTime
                 completionQueue:(dispatch_queue_t)queue
                      completion:(DPImageDownloaderCompleteBlock)completion
{
    if (!url) {
        [self execCompletion:completion queue:queue image:nil];
        return nil;
    }
    
    NSString* key = [self keyWithURL:url];
    
    // find cahce on memory
    DPImageDownloaderCache* cache = [self cacheForKey:key onMemory:YES expiresTime:lifeTime];
    if (cache.image) {
        [self execCompletion:completion queue:queue image:cache.image];
        return cache.image;
    }
    
    dispatch_async(_storageQueue, ^{
        DPImageDownloaderCache* cache = [self cacheForKey:key onMemory:NO expiresTime:lifeTime];
        if (cache.image) {
            dispatch_sync_main_thread(^{
                [_memoryCache setObject:cache forKey:key];
            });
            [self execCompletion:completion queue:queue image:cache.image];
            return;
        }
        
        NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30];
        
        void (^requestCompletion)(NSData*, NSURLResponse*, NSError*) = ^(NSData* data, NSURLResponse* urlResponse, NSError* connectionError){
            if (!data || connectionError) {
                [self execCompletion:completion queue:queue image:nil];
                return;
            }
            dispatch_async(_storageQueue, ^{
                DPImageDownloaderCache* cache = [DPImageDownloaderCache cacheWithData:data key:key];
                if (!cache.image) {
                    [self execCompletion:completion queue:queue image:nil];
                    return;
                }
                [cache saveFile];
                if (useOnMemoryCache) {
                    dispatch_sync_main_thread(^{
                        [self sweepMemoryCacheIfNeeded];
                        [_memoryCache setObject:cache forKey:key];
                    });
                }
                [self execCompletion:completion queue:queue image:cache.image];
            });
        };
        
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
        double versionNumber = NSFoundationVersionNumber_iOS_7_0;
#elif TARGET_OS_MAC
        double versionNumber = NSFoundationVersionNumber10_9;
#else
        double versionNumber = 1000;
#endif
        // iOS 6.x, OSX 10.8
        if (NSFoundationVersionNumber < versionNumber) {
            [[[self class] requestOperationQueue] addOperationWithBlock:^{
                NSURLResponse* res   = nil;
                NSError*       error = nil;
                NSData*        data  = [NSURLConnection sendSynchronousRequest:req returningResponse:&res error:&error];
                requestCompletion(data, res, error);
            }];
        }
        // iOS 7.x, OSX 10.9 or later
        else {
            [[[[self class] defaultURLSession] dataTaskWithRequest:req completionHandler:requestCompletion] resume];
        }
    });
    
    return nil;
}

#pragma mark - Private Methods

- (void)execCompletion:(DPImageDownloaderCompleteBlock)completion queue:(dispatch_queue_t)queue image:(DPImageType*)image
{
    if (!completion || !queue) {
        return;
    }
    
    if (queue == dispatch_get_main_queue() && [[NSThread currentThread] isMainThread]) {
        completion(image);
    }
    else {
        dispatch_async(queue, ^{
            completion(image);
        });
    }
}

- (NSString*)keyWithURL:(NSString*)url // get URLString MD5
{
    const char * cStr = [url UTF8String];
    unsigned char result[16];
    CC_MD5( cStr, (CC_LONG)strlen(cStr), result );
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
}

- (DPImageDownloaderCache*)cacheForKey:(NSString*)key onMemory:(BOOL)onMemory expiresTime:(NSUInteger)expiresTime
{
    if (onMemory) {
        __block DPImageDownloaderCache* cache;
        dispatch_sync_main_thread(^{
            cache = [_memoryCache objectForKey:key];
        });
        return cache;
    }
    else {
        DPImageDownloaderCache* cache = [DPImageDownloaderCache cacheFromStorageWithKey:key];
        if (cache) {
            if ([cache isExpiredWith:[[NSDate date] timeIntervalSince1970] lifeTime:expiresTime]) {
                dispatch_sync_main_thread(^{
                    [_memoryCache removeObjectForKey:key];
                });
                [cache deleteFile];
                return nil;
            }
            return cache;
        }
    }
    return nil;
}

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
- (void)memoryWarning
{
    dispatch_sync_main_thread(^{
        [_memoryCache removeAllObjects];
    });
}
#endif

- (void)sweepMemoryCacheIfNeeded {
    //@avishic: Basic implementation (Should be LRU)
    dispatch_sync_main_thread(^{
        if (_memoryCache.count > kMaxMemCacheItems) {
            [_memoryCache removeAllObjects];
        }
    });
}

#pragma mark - Private Class Method

+ (NSOperationQueue*)requestOperationQueue // for iOS 6, NSURLConnection
{
    static NSOperationQueue* queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 3;
    });
    return queue;
}

+ (NSURLSession*)defaultURLSession // for iOS 7
{
    static NSURLSession* session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.HTTPMaximumConnectionsPerHost = 3;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

@end
