//
//  FYContentLoader.m
//  FYCachedUrlAsset
//
//  Created by Yuriy Romanchenko on 4/23/15.
//  Copyright (c) 2015 FactorialComplexity. All rights reserved.
//

// Model
#import "FYContentProvider.h"
#import "FYCachedURLAsset.h"
#import "FYCachedStorage.h"

// Frameworks
@import MobileCoreServices;
@import SystemConfiguration;

static NSTimeInterval const kMaximumWaitingTimeTreshold = 5.0f;

typedef enum {
	// Regular streaming (over internet) or from cached file.
	kStreamingStateStreaming,
	// Streaming on demand (without caching). This happens when user wants to seek to specific times.
	kStreamingStateOnDemand
} StreamingState;

#pragma mark - FYContentRequester

@interface FYContentRequester : NSObject

/**
 *  Current streaming state for content requester.
 */
@property (nonatomic) StreamingState streamingState;

/**
 *  Original resource URL from which should be cached.
 */
@property (nonatomic) NSURL *resourceURL;

/**
 *  Total count of current requesters. Act like a reference counting mechanism.
 *	When it drops to zero it's treated as no one needs content from given URL.
 *	In this case content requester deallocates and performs cleanup.
 */
@property (nonatomic) NSInteger totalRequestersCount;

/**
 *  Total requests made from AVFoundation framework that are asking for media data.
 */
@property (nonatomic) NSMutableArray *pendingRequests;

/**
 *  Cache filename path to which data should be stored from resourceURL.
 */
@property (nonatomic) NSString *cacheFilenamePath;

/**
 *  Tells if current content provider is streaming data from local storage.
 */
@property (nonatomic) BOOL isStreamingFromCache;

/**
 *  Offset from the beggining of the file that is used when resuming download to approximate seeking time.
 */
@property (nonatomic) NSInteger resumeDownloadingOffset;

/**
 *  Raw media data that was fetched from given resource URL or from cached file.
 */
@property (nonatomic) NSMutableData *mediaData;

/**
 *  Connection that has been established for downloading from given resource URL.
 */
@property (nonatomic) NSURLConnection *connection;

/**
 *  Response for given connection. Used to check is cached resource up-to date or to get mime type and length.
 */
@property (nonatomic) NSHTTPURLResponse *response;

/**
 *  Date on which connection has been established. It's used for seeking situation.
 *	By approximating how fast we will download till new time we decide to invalidate caching and restart request or to wait.
 */
@property (nonatomic) NSDate *connectionDate;

@end

@implementation FYContentRequester

- (instancetype)initWithURL:(NSURL *)resourceURL cacheFilePath:(NSString *)path {
	if (self = [super init]) {
		_resourceURL = resourceURL;
		_cacheFilenamePath = path;

		_pendingRequests = [NSMutableArray new];
		_mediaData = [NSMutableData new];
		
		_totalRequestersCount = 1;
	}
	
	return self;
}

- (void)dealloc {
	NSLog(@"%s", __FUNCTION__);
}

@end

#pragma mark - FYContentProvider

typedef void (^FYReachabilityCallback) (BOOL isConnectedToTheInternet);

@interface FYContentProvider ()
<
AVAssetResourceLoaderDelegate,
NSURLConnectionDataDelegate
>
@end

@implementation FYContentProvider {
	// Reachability related.
	SCNetworkReachabilityRef _reachability;
	SCNetworkReachabilityFlags _latestReachabilityFlags;
	// General callback for reachability.
	FYReachabilityCallback _reachabilityCallback;
	// Callbacks that need to know current network status.
	NSMutableArray *_networkReachableWaiters;
	
	NSMutableArray *_contentRequesters;
}

#pragma mark - Singleton

+ (instancetype)shared {
	static id manager = nil;
	
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		manager = [self new];
	});
	
	return manager;
}

#pragma mark - Init

- (instancetype)init {
	if (self = [super init]) {
		_contentRequesters = [NSMutableArray new];
		
		_reachability = SCNetworkReachabilityCreateWithName(NULL, "www.google.com");
		_networkReachableWaiters = [NSMutableArray new];
		
		SCNetworkReachabilityContext ctx = {0};
		ctx.version = 0;
		ctx.info = (__bridge void *)(self);
		
		SCNetworkReachabilitySetCallback(_reachability, NetworkReachabilityCallBack, &ctx);
		SCNetworkReachabilityScheduleWithRunLoop(_reachability, CFRunLoopGetMain(), (CFStringRef)NSRunLoopCommonModes);
		
		_reachabilityCallback = ^(BOOL isReachable) {
			if (!isReachable) {
				// TODO: Invalidate everything
			}
		};
	}
	return self;
}

- (void)dealloc {
	// Thus it never happens, but this is good coding style to release allocated stuff.
	SCNetworkReachabilityUnscheduleFromRunLoop(_reachability, CFRunLoopGetMain(), NULL);
	CFRelease(_reachability);
}

#pragma mark - Public

- (void)startResourceLoadingFromURL:(NSURL *)url toCachedFilePath:(NSString *)cachedFilePath
			withResourceLoader:(AVAssetResourceLoader *)loader {
	[loader setDelegate:self queue:dispatch_get_main_queue()];
	
	// Check if we're already loading something from given URL.
	BOOL alreadyLoading = NO;
	
	for (FYContentRequester *requester in _contentRequesters) {
		if ([requester.resourceURL isEqual:url]) {
			alreadyLoading = YES;
			requester.totalRequestersCount++;
			break;
		}
	}
	
	NSLog(@"[ContentProvider]: Registering URL: %@. Already loading: %@", [url lastPathComponent], alreadyLoading ? @"YES" : @"NO");
	
	if (!alreadyLoading) {
		// We're not loading from given URL yet.
		FYContentRequester *requester = [[FYContentRequester alloc] initWithURL:url cacheFilePath:cachedFilePath];
		
		[_contentRequesters addObject:requester];
		
		[self determineIsNetworkReachableWithCallback:^(BOOL isConnectedToTheInternet) {
			// 1. If we have internet connection & cached version -> check on server is cached version is up-to date.
			// 2. If we have internet connection & !cached version -> create temp file and download data into it.
			// 3. If we don't have internet connection -> check for cached version on disk. If it's present -> play it.
			
			// TODO: Implement this flow at the end (checking if cached version changed on server).
			// For now simply check if we have cached file -> play it otherwise stream over internet.
			void (^startFetchingBlock) (NSURLRequest *request) = ^(NSURLRequest *request) {
				if (isConnectedToTheInternet) {
					[self startLoadingWithURLRequest:request forContentRequester:requester];
				} else {
					NSLog(@"[Warning]: Isn't connected to the internet. Can't stream over it.");
				}
			};
			
			NSString *metaFilePath = [cachedFilePath stringByAppendingString:[self metadataFileSuffix]];
			NSString *tempFilePath = [cachedFilePath stringByAppendingString:[self temporaryFileSuffix]];
			
			BOOL cachedFileExist = [[NSFileManager defaultManager] fileExistsAtPath:cachedFilePath];
			BOOL metaFileExist = [[NSFileManager defaultManager] fileExistsAtPath:metaFilePath];
			BOOL tempCachedFileExist = [[NSFileManager defaultManager] fileExistsAtPath:tempFilePath];
			
			if (metaFileExist && (cachedFileExist || tempCachedFileExist)) {
				NSLog(@"[ContentProvider]: Got cached file!");
				requester.response = [NSKeyedUnarchiver unarchiveObjectWithFile:metaFilePath];
				requester.mediaData = [[NSData dataWithContentsOfFile:cachedFileExist ? cachedFilePath : tempFilePath] mutableCopy];
				requester.isStreamingFromCache = cachedFileExist;
				
				if (!cachedFileExist) {
					NSLog(@"[ContentProvider]: Cached file isn't fully downloaded!");
					// Resume downloading non-fully cached file.
					NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
					
					NSString *etag = requester.response.allHeaderFields[@"ETag"];
					NSString *range = [NSString stringWithFormat:@"bytes=%lu-", (unsigned long)requester.mediaData.length];
					
					if (etag.length > 0) {
						[request setValue:etag forHTTPHeaderField:@"If-Range"];
					}
					
					[request setValue:range forHTTPHeaderField:@"Range"];
					startFetchingBlock(request);
				}
			} else {
				NSLog(@"[ContentProvider]: Hasn't got cached files. Will download from scratch!");
				startFetchingBlock([NSURLRequest requestWithURL:url]);
			}
			
// TODO:
//			if (isConnectedToTheInternet) {
//				NSURLRequest *request = [NSURLRequest requestWithURL:url];
//				requester.connection = [NSURLConnection connectionWithRequest:request delegate:self];
//				[requester.connection start];
//			} else {
//				 Find cached version of file, otherwise we can't do anything here.
//
//			}
		}];
	}
}

- (void)stopResourceLoadingFromURL:(NSURL *)url {
	FYContentRequester *requester = [self contentRequesterForURL:url];
	
	requester.totalRequestersCount--;

	if (requester.totalRequestersCount == 0) {
		for (AVAssetResourceLoadingRequest *request in requester.pendingRequests) {
			// TODO: Fill with normal error.
			[request finishLoadingWithError:[NSError errorWithDomain:NSCocoaErrorDomain
																code:0
															userInfo:nil]];
		}
		
		[requester.pendingRequests removeAllObjects];
		[requester.connection cancel];
		
		[_contentRequesters removeObject:requester];
	}
}

#pragma mark - Private

- (NSURL *)modifySongURL:(NSURL *)url withCustomScheme:(NSString *)scheme {
	NSURLComponents *components = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
	components.scheme = scheme;
 
	return [components URL];
}

- (FYContentRequester *)contentRequesterForURL:(NSURL *)url {
	for (FYContentRequester *requester in _contentRequesters) {
		NSURL *originalURL = [self modifySongURL:url withCustomScheme:requester.resourceURL.scheme];
		
		if ([requester.resourceURL isEqual:originalURL]) {
			return requester;
		}
	}
	
	return nil;
}

- (void)processAllPendingRequests {
	for (FYContentRequester *requester in _contentRequesters) {
		NSLog(@"Got %d requests", (int32_t)requester.pendingRequests.count);

		for (AVAssetResourceLoadingRequest *request in [requester.pendingRequests copy]) {
			BOOL didSatisfyRequest = [self tryToSatisfyRequest:request forRequester:requester];
			
			if (didSatisfyRequest) {
				[requester.pendingRequests removeObject:request];
			}
		}
	}
}

- (BOOL)tryToSatisfyRequest:(AVAssetResourceLoadingRequest *)request forRequester:(FYContentRequester *)requester {
	if (request.isCancelled) {
		// If request is cancelled - it somehow satisfied.
		return YES;
	}
	
	// Info / data requests are optional, we've handled them if they are not present.
	BOOL didRespondToInformationRequest = request.contentInformationRequest ? NO : YES;
	BOOL didRespondToDataRequest = request.dataRequest ? NO : YES;
	
	if (request.contentInformationRequest) {
		if (requester.response) {
			CFStringRef contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType,
																			(__bridge CFStringRef)(requester.response.MIMEType),
																			NULL);
			
			request.contentInformationRequest.contentType = CFBridgingRelease(contentType);
			request.contentInformationRequest.contentLength = requester.response.expectedContentLength;
			request.contentInformationRequest.byteRangeAccessSupported = YES;
			
			didRespondToInformationRequest = YES;
		}
	}
	
	if (request.dataRequest) {
		AVAssetResourceLoadingDataRequest *dataRequest = request.dataRequest;
		NSData *availableData = requester.mediaData;
		
		if (dataRequest.currentOffset < requester.resumeDownloadingOffset) {
			NSLog(@"[ContentProvider]: Couldn't satisfy request, because requested data is behind current download offset.");
			return NO;
		} else if (dataRequest.currentOffset <= availableData.length + requester.resumeDownloadingOffset) {
			CGFloat bytesGot = availableData.length + requester.resumeDownloadingOffset - request.dataRequest.currentOffset;
			CGFloat bytesToGive = MIN(bytesGot, dataRequest.requestedOffset + dataRequest.requestedLength - dataRequest.currentOffset);
			
			NSRange requestedDataRange = (NSRange) {
				request.dataRequest.currentOffset - requester.resumeDownloadingOffset,
				bytesToGive
			};
			
			[request.dataRequest respondWithData:[availableData subdataWithRange:requestedDataRange]];
			
			// If we gave something - we've responded to that request.
			didRespondToDataRequest = bytesToGive > 0;
		}
	}
	
	if (didRespondToDataRequest && didRespondToInformationRequest) {
		NSLog(@"Did handle request: %@", request.dataRequest);
		[request finishLoading];
		
		return YES;
	} else {
		return NO;
	}
}

- (NSString *)temporaryFileSuffix {
	return @"~part";
}

- (NSString *)metadataFileSuffix {
	return @"~meta";
}

- (void)startLoadingWithURLRequest:(NSURLRequest *)request forContentRequester:(FYContentRequester *)requester {
	requester.connection = [NSURLConnection connectionWithRequest:request delegate:self];
	[requester.connection start];
}

#pragma mark - SCNetworkReachability

- (void)determineIsNetworkReachableWithCallback:(FYReachabilityCallback)callback {
	if (_latestReachabilityFlags) {
		// If we have latest reachability flags -> use them.
		!callback ? : callback([self isReachableWithFlags:_latestReachabilityFlags]);
	} else {
		if (callback) {
			// Store callback, because network reachability isn't yet determined.
			[_networkReachableWaiters addObject:callback];
		}
	}
}

static void NetworkReachabilityCallBack(SCNetworkReachabilityRef target,
										SCNetworkReachabilityFlags flags,
										void *info) {
	FYContentProvider *self = (__bridge FYContentProvider *)(info);
	
	self->_latestReachabilityFlags = flags;
	!self->_reachabilityCallback ? : self->_reachabilityCallback([self isReachableWithFlags:flags]);

	NSArray *waiters = [self->_networkReachableWaiters copy];
	
	[self->_networkReachableWaiters removeAllObjects];
	
	for (FYReachabilityCallback reachabilityCallback in waiters) {
		reachabilityCallback([self isReachableWithFlags:flags]);
	}
}

- (BOOL)isReachableWithFlags:(SCNetworkReachabilityFlags)flags {
	SCNetworkReachabilityFlags airplaneFlags = kSCNetworkReachabilityFlagsConnectionRequired |
												kSCNetworkReachabilityFlagsTransientConnection;
	
	return (flags & kSCNetworkReachabilityFlagsReachable) &&
			((flags & airplaneFlags) != airplaneFlags);
}

#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
	NSLog(@"Wanted to wait for loading for request: %@", loadingRequest.dataRequest);
	FYContentRequester *requester = [self contentRequesterForURL:loadingRequest.request.URL];

	// Try to satisfy this request right now.
	BOOL didSatisfy = [self tryToSatisfyRequest:loadingRequest forRequester:requester];
	
	if (!didSatisfy) {
		// If we didn't satisfy request -> add it to pending request to process later.
		[requester.pendingRequests addObject:loadingRequest];
		// Process other pending requests that may now be satisfied.
		[self processAllPendingRequests];
		
		// If we're not streaming from cache and we have active connection and loading request is asking for data then:
		if (!requester.isStreamingFromCache && requester.connectionDate && loadingRequest.dataRequest) {
			// If datax request is asking for data that we didn't have yet - calculate how much bytes we are from requested offset.
			NSInteger bytesToDownload = loadingRequest.dataRequest.requestedOffset - (requester.mediaData.length + requester.resumeDownloadingOffset);
			NSLog(@"KBytes to download: %d", (int32_t)bytesToDownload / 1024);
			
			if (bytesToDownload > 0) {
				// Calculate average download speed and how much time we need to catch up with requested offset.
				NSTimeInterval timePassed = -[requester.connectionDate timeIntervalSinceNow];
				NSInteger totalBytesDownloaded = requester.mediaData.length;
				
				CGFloat bytesPerSecond = totalBytesDownloaded / timePassed;
				
				CGFloat approximateTimeForSeeking = bytesToDownload / bytesPerSecond;
				NSLog(@"[ContentProvider]: Time passed: %.2fs. AVG: %.2f KBps. Approximate: %.2f (KBytes to download: %d)", timePassed, bytesPerSecond / 1024, approximateTimeForSeeking, (int32_t)bytesToDownload / 1024);
				
				if (approximateTimeForSeeking > kMaximumWaitingTimeTreshold) {
					NSLog(@"[ContentProvider]: Will transite ON DEMAND state!");
					requester.streamingState = kStreamingStateOnDemand;
					
					// Perform cleanup and several adjustments to fetch data from requested offset.
					[requester.connection cancel];
					requester.connection = nil;
					requester.connectionDate = nil;
					
					for (AVAssetResourceLoadingRequest *request in requester.pendingRequests) {
						if (request != loadingRequest) {
							[request finishLoadingWithError:nil];
						}
					}
					
					[requester.pendingRequests removeAllObjects];
					[requester.pendingRequests addObject:loadingRequest];
					requester.resumeDownloadingOffset = loadingRequest.dataRequest.requestedOffset;
					[requester.mediaData setLength:0];
					
					// Build headers to request data from requested offset.
					NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requester.resourceURL];
					
					NSString *etag = requester.response.allHeaderFields[@"ETag"];
					NSString *range = [NSString stringWithFormat:@"bytes=%lu-", (unsigned long)requester.resumeDownloadingOffset];
					
					if (etag.length > 0) {
						[request setValue:etag forHTTPHeaderField:@"If-Range"];
					}
					
					[request setValue:range forHTTPHeaderField:@"Range"];

					[self startLoadingWithURLRequest:request forContentRequester:requester];
				} else {
					NSLog(@"[ContentProvider]: Will wait %.2f seconds...", approximateTimeForSeeking);
				}
			} else if (requester.resumeDownloadingOffset > loadingRequest.dataRequest.requestedOffset) {
				requester.streamingState = kStreamingStateOnDemand;

				// Perform cleanup and several adjustments to fetch data from requested offset.
				[requester.connection cancel];
				requester.connection = nil;
				requester.connectionDate = nil;
				
				for (AVAssetResourceLoadingRequest *request in requester.pendingRequests) {
					if (request != loadingRequest) {
						[request finishLoadingWithError:nil];
					}
				}
				
				[requester.pendingRequests removeAllObjects];
				[requester.pendingRequests addObject:loadingRequest];
				requester.resumeDownloadingOffset = loadingRequest.dataRequest.requestedOffset;
				[requester.mediaData setLength:0];
				
				// Build headers to request data from requested offset.
				NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requester.resourceURL];
				
				NSString *etag = requester.response.allHeaderFields[@"ETag"];
				NSString *range = [NSString stringWithFormat:@"bytes=%lu-", (unsigned long)requester.resumeDownloadingOffset];
				
				if (etag.length > 0) {
					[request setValue:etag forHTTPHeaderField:@"If-Range"];
				}
				
				[request setValue:range forHTTPHeaderField:@"Range"];
				
				[self startLoadingWithURLRequest:request forContentRequester:requester];
			}

		}
	}

	return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
	FYContentRequester *requester = [self contentRequesterForURL:loadingRequest.request.URL];
	
	[requester.pendingRequests removeObject:loadingRequest];
}

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	// TODO: Rework this logic. 206 means partial content, but in my case it gave me full content from specified range.
	// Maybe it can return not full range, needs testing.
	NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
	NSLog(@"Response: %@", httpResponse);
	FYContentRequester *requester = [self contentRequesterForURL:connection.originalRequest.URL];
	
	//	 TODO: In future version:
	// Check if we already have cached file and if yes -> check if it's up-to date.
	
	if (httpResponse.statusCode == 200 || httpResponse.statusCode == 206) {
		// Store additional info.
		if (!requester.response) {
			requester.response = httpResponse;
			
			// Save response in metadata file.
			NSString *metadataFilePath = [requester.cacheFilenamePath stringByAppendingString:[self metadataFileSuffix]];
			NSData *metadataBytes = [NSKeyedArchiver archivedDataWithRootObject:response];
			[metadataBytes writeToFile:metadataFilePath atomically:NO];
		}
		
		requester.connectionDate = [NSDate date];
		
		[self processAllPendingRequests];
	} else {
		NSLog(@"Will cancel connection!");
		[connection cancel];
		
		// TODO: Invalidate.
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	static int failer = 0;
	
	FYContentRequester *requester = [self contentRequesterForURL:connection.originalRequest.URL];
	
	[requester.mediaData appendData:data];
	
	NSLog(@"%d/%d KB", (int32_t)requester.mediaData.length / 1024 + requester.resumeDownloadingOffset / 1024, (int32_t)requester.response.expectedContentLength / 1024);
	
	[self processAllPendingRequests];
	
	failer++;
	
	if (failer == 10) {
		NSLog(@"Will FAIL!");
//		[connection cancel];
//		[self connection:connection didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain
//																		 code:0
//																	 userInfo:@{NSLocalizedDescriptionKey : @"TEST"}]];
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	NSLog(@"%s", __FUNCTION__);
	[self processAllPendingRequests];
	
	FYContentRequester *requester = [self contentRequesterForURL:connection.originalRequest.URL];

	if (requester.streamingState == kStreamingStateStreaming) {
		[requester.mediaData writeToFile:requester.cacheFilenamePath atomically:NO];
		
		// Cleanup any temp files that may exist in case of resuming download.
		NSString *tempFilePath = [requester.cacheFilenamePath stringByAppendingString:[self temporaryFileSuffix]];
		[[NSFileManager defaultManager] removeItemAtPath:tempFilePath error:nil];
	}
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	NSLog(@"%s", __FUNCTION__);
	// Save all gathered data to ~part file.
	FYContentRequester *requester = [self contentRequesterForURL:connection.originalRequest.URL];

	if (requester.mediaData.length > 0 && requester.streamingState == kStreamingStateStreaming) {
		
		NSString *partFilePath = [requester.cacheFilenamePath stringByAppendingString:@"~part"];

		[requester.mediaData writeToFile:partFilePath atomically:NO];
	}
	
	// TOOD: Invalidate
}

@end
