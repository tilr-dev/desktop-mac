#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// ABI 1. Only Objective-C/Foundation/AppKit values cross the binary boundary.
// All calls, callbacks and view access run on the main thread. The host outlives
// its plugin session; plugins must hold it weakly. Configuration contains JSON.
@protocol TLRPluginHost <NSObject>
@property(nonatomic, readonly) NSString *origin;
@property(nonatomic, readonly) NSView *viewContainer;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *configuration;
@property(nonatomic, readonly, nullable) NSUUID *storageIdentifier;
- (NSUUID *)persistentIdentifier:(NSUUID *)identifier;
- (nullable NSURL *)resolveSiteURL:(NSURL *)url;
- (void)emit:(NSString *)event detail:(NSDictionary<NSString *, id> *)detail;
@end

@protocol TLRNativePlugin <NSObject>
@property(nonatomic, readonly) NSInteger abiVersion;
- (void)startWithHost:(id<TLRPluginHost>)host NS_SWIFT_NAME(start(host:));
// Legacy web message aliases are declared in the package manifest, not the app.
- (void)receive:(NSDictionary<NSString *, id> *)message channel:(NSString *)channel;
// Invoked only by the trusted native control socket. Never exposed to websites.
- (void)request:(NSDictionary<NSString *, id> *)request
        service:(NSString *)service
     identifier:(NSString *)identifier
     completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion;
// Cancel a request before timeout, tab removal or caller cancellation. Completion may
// arrive late; the host ignores it. Implementations must stop subsequent side effects.
- (void)cancelRequest:(NSString *)identifier;
- (void)pageDidNavigate;
- (void)configurationDidChange;
// Releases all players/views/listeners. Loaded code remains resident until exit.
- (void)stop;
@end

// A module exports tilr_plugin_create_v1, returning a retained NSObject conforming
// to TLRNativePlugin. The caller takes ownership. No Swift type crosses this ABI.
typedef void * _Nullable (*TLRPluginCreateV1)(void);

NS_ASSUME_NONNULL_END
