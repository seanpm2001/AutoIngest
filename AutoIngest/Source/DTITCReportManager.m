//
//  DTITCReportManager.m
//  AutoIngest
//
//  Created by Oliver Drobnik on 19.04.13.
//  Copyright (c) 2013 Cocoanetics. All rights reserved.
//

#import "DTITCReportManager.h"
#import "DTITCReportDownloadOperation.h"

#import "AccountManager.h"

#import "NSTimer-NoodleExtensions.h"

static DTITCReportManager *_sharedInstance = nil;

NSString * const DTITCReportManagerSyncDidStartNotification = @"DTITCReportManagerSyncDidStartNotification";
NSString * const DTITCReportManagerSyncDidFinishNotification = @"DTITCReportManagerSyncDidFinishNotification";


@interface DTITCReportManager () <DTITCReportDownloadOperationDelegate>

@property (strong) NSError *error;

@end

@implementation DTITCReportManager
{	
	NSString *_reportFolder;
	NSString *_vendorID;
	
	NSOperationQueue *_queue;
	
	NSTimer *_autoSyncTimer;
}

+ (DTITCReportManager *)sharedManager
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_sharedInstance = [[DTITCReportManager alloc] init];
	});
	
	return _sharedInstance;
}

- (id)init
{
	self = [super init];
	
	if (self)
	{
		_queue = [[NSOperationQueue alloc] init];
		_queue.maxConcurrentOperationCount = 1;
		
		// load initial defaults
		[self defaultsDidUpdate:nil];
		
		// observe for defaults changes, e.g. download path
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(defaultsDidUpdate:) name:NSUserDefaultsDidChangeNotification object:nil];
	}
	
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void)_downloadAllReportsOfType:(ITCReportType)reportType subType:(ITCReportSubType)reportSubType dateType:(ITCReportDateType)reportDateType fromAccount:(GenericAccount *)account
{
	DTITCReportDownloadOperation *op = [[DTITCReportDownloadOperation alloc] initForReportsOfType:reportType subType:reportSubType dateType:reportDateType fromAccount:account vendorID:_vendorID intoFolder:_reportFolder];
	op.uncompressFiles = [[NSUserDefaults standardUserDefaults] boolForKey:AIUserDefaultsShouldUncompressReportsKey];
	op.delegate = self;
	
	[_queue addOperation:op];
}

- (void)_reportCompletionWithError:(NSError *)error
{
	NSDictionary *userInfo = nil;
	
	if (error)
	{
		userInfo = @{@"Error": _error};
	}
	
	[[NSNotificationCenter defaultCenter] postNotificationName:DTITCReportManagerSyncDidFinishNotification object:self userInfo:userInfo];
}

- (void)startSync
{
	if (_isSynching)
	{
		NSLog(@"Already Synching");
		return;
	}
	
	if (![self canSync])
	{
		NSLog(@"Cannot start sync because some setup is missing");
		return;
	}
	
	// reset error status
	self.error = nil;
	
	NSArray *accounts = [[AccountManager sharedAccountManager] accountsOfType:@"iTunes Connect"];
	
	if (![accounts count])
	{
		NSLog(@"No account configured");
		return;
	}
	
	// only one account support initially
	GenericAccount *account = accounts[0];
	
	if (!account.password)
	{
		NSLog(@"Account configured, but no password set");
		return;
	}
	
	if (![_vendorID integerValue] || (![_vendorID hasPrefix:@"8"] || [_vendorID length]!=8))
	{
		NSLog(@"Invalid Vendor ID, must be numeric and begin with an 8 and be 8 digits");
		return;
	}
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	__weak DTITCReportManager *weakself = self;
	
	BOOL hasWorkToDo = NO;
	
	[_queue setSuspended:YES];
	
	if ([defaults boolForKey:@"DownloadDaily"])
	{
		[self _downloadAllReportsOfType:ITCReportTypeSales subType:ITCReportSubTypeSummary dateType:ITCReportDateTypeDaily fromAccount:account];
		
		hasWorkToDo = YES;
	}
	
	if ([defaults boolForKey:@"DownloadWeekly"])
	{
		[self _downloadAllReportsOfType:ITCReportTypeSales subType:ITCReportSubTypeSummary dateType:ITCReportDateTypeWeekly fromAccount:account];
		
		hasWorkToDo = YES;
	}
	
	if ([defaults boolForKey:@"DownloadMonthly"])
	{
		[self _downloadAllReportsOfType:ITCReportTypeSales subType:ITCReportSubTypeSummary dateType:ITCReportDateTypeMonthly fromAccount:account];
		
		hasWorkToDo = YES;
	}
	
	if ([defaults boolForKey:@"DownloadYearly"])
	{
		[self _downloadAllReportsOfType:ITCReportTypeSales subType:ITCReportSubTypeSummary dateType:ITCReportDateTypeYearly fromAccount:account];
		
		hasWorkToDo = YES;
	}
	
	// completion
	[_queue addOperationWithBlock:^{
		[weakself _reportCompletionWithError:_error];
		
		_isSynching = NO;
	}];
	
	if (!hasWorkToDo)
	{
		NSLog(@"Nothing to do for synching!");
		return;
	}
	
	NSLog(@"Starting Sync");
	
	[[NSNotificationCenter defaultCenter] postNotificationName:DTITCReportManagerSyncDidStartNotification object:weakself];
	
	[_queue setSuspended:NO];
	
	_isSynching = YES;
}

- (void)stopSync
{
	if (!_isSynching)
	{
		return;
	}
	
	NSLog(@"Stopped Sync");
	
	[_queue setSuspended:YES];
	
	// cancel only download operations
	for (NSOperation *op in [_queue operations])
	{
		if ([op isKindOfClass:[DTITCReportDownloadOperation class]])
		{
			[op cancel];
		}
	}
	
	// now the completion block should follow
	[_queue setSuspended:NO];

	
	_isSynching = NO;
}

- (BOOL)canSync
{
	NSArray *accounts = [[AccountManager sharedAccountManager] accountsOfType:@"iTunes Connect"];
	
	if (![accounts count])
	{
		return NO;
	}
	
	NSString *vendorID = [[NSUserDefaults standardUserDefaults] objectForKey:AIUserDefaultsVendoIDKey];
	
	// vendor ID must be only digits
	if ([[vendorID stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"]] length])
	{
		return NO;
	}
	
	if (![vendorID integerValue] || (![vendorID hasPrefix:@"8"] || [vendorID length]!=8))
	{
		return NO;
	}
	
	NSString *reportFolder = [[NSUserDefaults standardUserDefaults] objectForKey:AIUserDefaultsDownloadFolderPathKey];
	BOOL isDirectory = NO;
	if ([[NSFileManager defaultManager] fileExistsAtPath:reportFolder isDirectory:&isDirectory])
	{
		if (!isDirectory)
		{
			return NO;
		}
	}
	else
	{
		return NO;
	}
	
	BOOL hasWorkToDo = NO;
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([defaults boolForKey:@"DownloadDaily"])
	{
		hasWorkToDo = YES;
	}
	
	if ([defaults boolForKey:@"DownloadWeekly"])
	{
		hasWorkToDo = YES;
	}
	
	if ([defaults boolForKey:@"DownloadMonthly"])
	{
		hasWorkToDo = YES;
	}
	
	if ([defaults boolForKey:@"DownloadYearly"])
	{
		hasWorkToDo = YES;
	}
	
	if (!hasWorkToDo)
	{
		return NO;
	}
	
	return YES;
}

#pragma mark - Auto Sync
- (void)scheduledNextAutoSyncTimer
{
	[_autoSyncTimer invalidate];
	
	NSDate *today = [NSDate date];
	NSDate *nextDate = nil;
	NSInteger dayOffset = 1;
	
	NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
	NSDateComponents *components = [[NSDateComponents alloc] init];
	components.day = dayOffset;
	nextDate = [gregorian dateByAddingComponents:components toDate:today options:0];
	
	_autoSyncTimer = [NSTimer scheduledTimerWithAbsoluteFireDate:nextDate block:^(NSTimer *timer) {
		[self startSync];
		
		[self scheduledNextAutoSyncTimer];
	}];

}

- (void)startAutoSyncTimer
{
	[self scheduledNextAutoSyncTimer];
	
	NSLog(@"AutoSync Timer enabled");
}

- (void)stopAutoSyncTimer
{
	[_autoSyncTimer invalidate];
	_autoSyncTimer = nil;
	
	NSLog(@"AutoSync Timer disabled");
}

#pragma mark - Notifications

- (void)defaultsDidUpdate:(NSNotification *)notification
{
	
	BOOL needsToStopSync = NO;
	
	NSString *reportFolder = [[NSUserDefaults standardUserDefaults] objectForKey:AIUserDefaultsDownloadFolderPathKey];
	NSString *vendorID = [[NSUserDefaults standardUserDefaults] objectForKey:AIUserDefaultsVendoIDKey];
   
	if (![_reportFolder isEqualToString:reportFolder])
	{
		NSLog(@"Report Download Folder changed to %@", reportFolder);
		_reportFolder = reportFolder;
		
		needsToStopSync = YES;
	}
	
	if (![_vendorID isEqualToString:vendorID])
	{
		NSLog(@"Vendor ID changed to %@", vendorID);
		_vendorID = vendorID;
		
		needsToStopSync = YES;
	}
	
	// need to stop sync, folder changed
	if (_isSynching && needsToStopSync)
	{
		[self stopSync];
	}
	
	BOOL needsAutoSync = [[NSUserDefaults standardUserDefaults] boolForKey:AIUserDefaultsShouldAutoSyncKey];
	BOOL hasActiveTimer = (_autoSyncTimer!=nil);
	
	if (needsAutoSync != hasActiveTimer)
	{
		if (needsAutoSync)
		{
			[self startAutoSyncTimer];
		}
		else
		{
			[self stopAutoSyncTimer];
		}
	}
}

#pragma mark - DTITCReportDownloadOperation Delegate

- (void)operation:(DTITCReportDownloadOperation *)operation didFailWithError:(NSError *)error
{
	self.error = error;
	
	[self stopSync];
}


@end
