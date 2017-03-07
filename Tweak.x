#import <UIKit/UIKit.h>
#import <AppList/ALApplicationList.h>

#import "PrivateAPIs.h"

static NSDictionary *schemeMapping;
static NSInteger suppressed;
static CGPoint lastTapCentroid;
static NSInteger shouldBreadcrumb;

static inline NSString *BCActiveDisplayIdentifier(void)
{
	return [[NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.rpetrich.browserchooser.plist"] objectForKey:@"BCActiveDisplayIdentifier"];
}

static inline NSString *BCReplaceSafariWordInText(NSString *text)
{
	if (text && [text rangeOfString:@"Safari"].location != NSNotFound) {
		// Because Flipboard inspects the button text, we ignore in this app
		if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.flipboard.flipboard-ipad"]) {
			NSString *displayIdentifier = BCActiveDisplayIdentifier();
			NSString *newAppName = displayIdentifier ? [[ALApplicationList sharedApplicationList].applications objectForKey:displayIdentifier] : @"Browser";
			if ([newAppName length]) {
				return [text stringByReplacingOccurrencesOfString:@"Safari" withString:newAppName];
			}
		}
	}
	return text;
}

static inline BOOL BCApplySchemeReplacementForDisplayIdentifierOnURL(NSString *displayIdentifier, NSURL *url, NSURL **outURL)
{
	NSDictionary *identifierMapping = [schemeMapping objectForKey:displayIdentifier];
	if (identifierMapping) {
		NSString *oldScheme = [url.scheme lowercaseString];
		NSString *absoluteString;
		if ([oldScheme isEqualToString:@"x-web-search"]) {
			oldScheme = @"http";
			if ([[url host] isEqualToString:@"wikipedia"]) {
				absoluteString = @"http://en.m.wikipedia.org/?search=";
			} else {
				absoluteString = @"http://www.google.com/search?q=";
			}
			absoluteString = [absoluteString stringByAppendingString:[url query]];
		} else {
			absoluteString = [url absoluteString];
		}
		NSString *newScheme = [identifierMapping objectForKey:oldScheme];
		BOOL encoded = [[identifierMapping objectForKey:@"encoded"] boolValue];
		if (newScheme){
			if (!encoded)
				*outURL = [NSURL URLWithString:[newScheme stringByAppendingString:[absoluteString substringFromIndex:oldScheme.length]]];
			else {
				NSString *encodedString = [(NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,(CFStringRef)[absoluteString substringFromIndex:oldScheme.length], NULL,CFSTR(":/=,!$& '()*+;[]@#?"),kCFStringEncodingUTF8) autorelease];
				*outURL = [NSURL URLWithString:[newScheme stringByAppendingString:encodedString]];
			}
			return YES;
		}
	}
	return NO;
}

static inline BOOL BCURLPassesPrefilter(NSURL *url)
{
	BOOL isYouTubeURL = [url respondsToSelector:@selector(youTubeURL)] && [url youTubeURL];
	BOOL isGamecenterURL = [url respondsToSelector:@selector(gamecenterURL)] && [url gamecenterURL];

	return ![url isStoreServicesURL] && ![url isWebcalURL] && ![url mapsURL] && !isYouTubeURL && !isGamecenterURL && ![url appleStoreURL];
}

__attribute__((visibility("hidden")))
@interface BCChooserViewController : UIViewController <UIActionSheetDelegate> {
@private
	NSURL *_url;
	id _sender;
	unsigned _additionalActivationFlag;
	id _objectAdditionalFlags;
	NSDictionary *_displayIdentifierTitles;
	NSArray *_orderedDisplayIdentifiers;
	UIActionSheet *_actionSheet;
	UIWindow *_alertWindow;
	id _activationHandler;
}
@end

@implementation BCChooserViewController

- (id)initWithURL:(NSURL *)url originalSender:(id)sender additionalActivationFlag:(unsigned)additionalActivationFlag objectAdditionalFlags:(id)objectAdditionalFlags activationHandler:(id)activationHandler
{
	if ((self = [super init])) {
		_url = [url retain];
		_sender = [sender retain];
		_additionalActivationFlag = additionalActivationFlag;
		_displayIdentifierTitles = [[[ALApplicationList sharedApplicationList] applicationsFilteredUsingPredicate:[NSPredicate predicateWithFormat:@"isBrowserChooserBrowser = TRUE"]] copy];
		_orderedDisplayIdentifiers = [[_displayIdentifierTitles allKeys] retain];
		_objectAdditionalFlags = [objectAdditionalFlags retain];
		_activationHandler = [activationHandler copy];
		self.wantsFullScreenLayout = YES;
	}
	return self;
}

- (void)dealloc
{
	[_activationHandler release];
	[_objectAdditionalFlags release];
	[_actionSheet release];
	[_alertWindow release];
	[_orderedDisplayIdentifiers release];
	[_displayIdentifierTitles release];
	[_sender release];
	[_url release];
	[super dealloc];
}

- (void)show
{
	if (!_actionSheet) {
		UIActionSheet *actionSheet = _actionSheet = [[UIActionSheet alloc] init];
		actionSheet.title = @"BrowserChooser";
		actionSheet.delegate = self;
		BOOL respondsToAddMediaButton = [actionSheet respondsToSelector:@selector(addMediaButtonWithTitle:iconView:andTableIconView:)];
		for (NSString *key in _orderedDisplayIdentifiers) {
			NSString *title = [_displayIdentifierTitles objectForKey:key];
			UIImage *image;
			if (respondsToAddMediaButton && (image = [[ALApplicationList sharedApplicationList] iconOfSize:ALApplicationIconSizeSmall forDisplayIdentifier:key])) {
				if ([image respondsToSelector:@selector(imageWithRenderingMode:)]) {
					image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
				}
				UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
				[_actionSheet addMediaButtonWithTitle:title iconView:imageView andTableIconView:imageView];
				[imageView release];
			} else {
				[_actionSheet addButtonWithTitle:title];
			}
		}
		NSInteger cancelButtonIndex = [actionSheet addButtonWithTitle:@"Cancel"];
		if (!_alertWindow) {
			_alertWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
			_alertWindow.windowLevel = 1050.1f /*UIWindowLevelStatusBar*/;
		}
		_alertWindow.hidden = NO;
		_alertWindow.rootViewController = self;
		if ([_alertWindow respondsToSelector:@selector(_updateToInterfaceOrientation:animated:)])
			[_alertWindow _updateToInterfaceOrientation:[(SpringBoard *)UIApp _frontMostAppOrientation] animated:NO];
		if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
			CGRect bounds;
			if ((lastTapCentroid.x == 0.0f) || (lastTapCentroid.y == 0.0f) || isnan(lastTapCentroid.x) || isnan(lastTapCentroid.y)) {
				bounds = self.view.bounds;
				bounds.origin.y += bounds.size.height;
				bounds.size.height = 0.0f;
			} else {
				bounds.origin.x = lastTapCentroid.x - 1.0f;
				bounds.origin.y = lastTapCentroid.y - 1.0f;
				bounds.size.width = 2.0f;
				bounds.size.height = 2.0f;
			}
			[actionSheet showFromRect:bounds inView:self.view animated:YES];
		} else {
			actionSheet.cancelButtonIndex = cancelButtonIndex;
			[actionSheet showInView:self.view];
		}
	}
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
	[self retain];
	if (buttonIndex >= 0 && buttonIndex != actionSheet.cancelButtonIndex && buttonIndex < [_orderedDisplayIdentifiers count]) {
		NSURL *adjustedURL = _url;
		NSString *displayIdentifier = [_orderedDisplayIdentifiers objectAtIndex:buttonIndex];
		BCApplySchemeReplacementForDisplayIdentifierOnURL(displayIdentifier, adjustedURL, &adjustedURL);
		suppressed++;
		if ([UIApp respondsToSelector:@selector(applicationOpenURL:withApplication:publicURLsOnly:animating:needsPermission:activationSettings:withResult:)]) {
			shouldBreadcrumb++;
			[(SpringBoard *)UIApp applicationOpenURL:adjustedURL withApplication:nil publicURLsOnly:NO animating:YES needsPermission:NO activationSettings:_objectAdditionalFlags withResult:nil];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
				shouldBreadcrumb--;
			});
		} else if ([UIApp respondsToSelector:@selector(applicationOpenURL:withApplication:sender:publicURLsOnly:animating:needsPermission:activationSettings:withResult:)]) {
			shouldBreadcrumb++;
			[(SpringBoard *)UIApp applicationOpenURL:adjustedURL withApplication:nil sender:_sender publicURLsOnly:NO animating:YES needsPermission:NO activationSettings:_objectAdditionalFlags withResult:nil];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
				shouldBreadcrumb--;
			});
		} else if ([UIApp respondsToSelector:@selector(applicationOpenURL:withApplication:sender:publicURLsOnly:animating:needsPermission:additionalActivationFlags:activationHandler:)]) {
			[(SpringBoard *)UIApp applicationOpenURL:adjustedURL publicURLsOnly:NO];
		} else if ([UIApp respondsToSelector:@selector(applicationOpenURL:publicURLsOnly:animating:sender:additionalActivationFlag:)]) {
			[(SpringBoard *)UIApp applicationOpenURL:adjustedURL publicURLsOnly:NO animating:YES sender:_sender additionalActivationFlag:_additionalActivationFlag];
		} else {
			[(SpringBoard *)UIApp applicationOpenURL:adjustedURL withApplication:nil sender:_sender publicURLsOnly:NO animating:YES needsPermission:NO additionalActivationFlags:nil];
		}
		suppressed--;
	}
	_actionSheet.delegate = nil;
	[_actionSheet release];
	_actionSheet = nil;
	_alertWindow.hidden = YES;
	_alertWindow.rootViewController = nil;
	[_alertWindow release];
	_alertWindow = nil;
	[self autorelease];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
{
	return (toInterfaceOrientation == UIInterfaceOrientationPortrait) || ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad);
}

@end


%group SpringBoard

%hook SBApplication

%new(c@:)
- (BOOL)isBrowserChooserBrowser
{
	NSString *displayIdentifier = [self respondsToSelector:@selector(displayIdentifier)] ? self.displayIdentifier : self.bundleIdentifier;
	return [schemeMapping objectForKey:displayIdentifier] != nil;
}

%end

%hook SBBookmarkIcon

- (void)launch
{
	UIWebClip *webClip = [self webClip];
	NSURL *url = webClip.pageURL;
	if (BCURLPassesPrefilter(url)) {
		if ([UIApp respondsToSelector:@selector(applicationOpenURL:withApplication:publicURLsOnly:animating:needsPermission:activationSettings:withResult:)]) {
			[(SpringBoard *)UIApp applicationOpenURL:url withApplication:nil publicURLsOnly:NO animating:YES needsPermission:NO activationSettings:nil withResult:nil];
		} else if ([UIApp respondsToSelector:@selector(applicationOpenURL:publicURLsOnly:animating:sender:additionalActivationFlag:)]) {
			[(SpringBoard *)UIApp applicationOpenURL:url publicURLsOnly:NO animating:YES sender:nil additionalActivationFlag:0];
		} else {
			[(SpringBoard *)UIApp applicationOpenURL:url withApplication:nil sender:nil publicURLsOnly:NO animating:YES needsPermission:NO additionalActivationFlags:nil];
		}
	} else {
		%orig;
	}
}

%end

%hook SpringBoard

typedef enum {
	BCNoMappingApplied,
	BCMappedToUIElement,
	BCMappedToNewApplication,
} BCMappingApplied;

static inline BCMappingApplied BCApplyMappingAndOptionallyConsumeURL(NSURL **url, id *display, id sender, unsigned additionalActivationFlag, id objectAdditionalFlags, id activationHandler)
{
	if (!suppressed && BCURLPassesPrefilter(*url)) {
		NSString *displayIdentifier = BCActiveDisplayIdentifier();
		if (displayIdentifier) {
			if (BCApplySchemeReplacementForDisplayIdentifierOnURL(displayIdentifier, *url, url)) {
				if (display) {
					SBApplicationController *applicationController = [%c(SBApplicationController) sharedInstance];
					SBApplication *newDisplay = [applicationController respondsToSelector:@selector(applicationWithDisplayIdentifier:)] ? [applicationController applicationWithDisplayIdentifier:displayIdentifier] : [applicationController applicationWithBundleIdentifier:displayIdentifier];
					if (newDisplay) {
						*display = newDisplay;
					}
				}
				return BCMappedToNewApplication;
			}
		} else {
			NSString *scheme = (*url).scheme;
			if ([scheme hasPrefix:@"http"] || [scheme isEqualToString:@"x-web-search"]) {
				BCChooserViewController *vc = [[BCChooserViewController alloc] initWithURL:*url originalSender:sender additionalActivationFlag:additionalActivationFlag objectAdditionalFlags:objectAdditionalFlags activationHandler:activationHandler];
				[vc performSelector:@selector(show) withObject:nil afterDelay:0.0];
				[vc release];
				return BCMappedToUIElement;
			}
		}
	}
	return BCNoMappingApplied;
}

// iOS 5/6

- (void)applicationOpenURL:(NSURL *)url publicURLsOnly:(BOOL)only animating:(BOOL)animating sender:(id)sender additionalActivationFlag:(unsigned)additionalActivationFlag
{
	if (BCApplyMappingAndOptionallyConsumeURL(&url, NULL, sender, additionalActivationFlag, nil, nil) != BCNoMappingApplied)
		%orig();
}

- (void)_openURLCore:(NSURL *)url display:(id)display animating:(BOOL)animating sender:(id)sender additionalActivationFlags:(id)flags
{
	if (BCApplyMappingAndOptionallyConsumeURL(&url, &display, sender, 0, flags, nil) != BCNoMappingApplied)
		%orig();
}

// iOS 7

- (void)_applicationOpenURL:(NSURL *)url withApplication:(id)display sender:(id)sender publicURLsOnly:(BOOL)publicOnly animating:(BOOL)animating additionalActivationFlags:(id)activationFlags activationHandler:(id)activationHandler
{
	switch (BCApplyMappingAndOptionallyConsumeURL(&url, &display, sender, 0, activationFlags, activationHandler)) {
		case BCNoMappingApplied:
			return %orig();
		case BCMappedToUIElement:
			return;
		case BCMappedToNewApplication:
			suppressed++;
			[self applicationOpenURL:url publicURLsOnly:NO];
			suppressed--;
			return;
	}
}

- (void)_openURLCore:(NSURL *)url display:(id)display animating:(BOOL)animating sender:(id)sender additionalActivationFlags:(id)activationFlags activationHandler:(id)activationHandler
{
	switch (BCApplyMappingAndOptionallyConsumeURL(&url, &display, sender, 0, activationFlags, activationHandler)) {
		case BCNoMappingApplied:
			return %orig();
		case BCMappedToUIElement:
			return;
		case BCMappedToNewApplication:
			suppressed++;
			[self applicationOpenURL:url publicURLsOnly:NO];
			suppressed--;
			return;
	}
}

// iOS 8

- (void)_openURLCore:(NSURL *)url display:(id)display animating:(BOOL)animating sender:(id)sender activationSettings:(id)activationSettings withResult:(id)resultHandler
{
	switch (BCApplyMappingAndOptionallyConsumeURL(&url, &display, sender, 0, activationSettings, resultHandler)) {
		case BCNoMappingApplied:
			return %orig();
		case BCMappedToUIElement:
			return;
		case BCMappedToNewApplication:
			suppressed++;
			shouldBreadcrumb++;
			if ([self respondsToSelector:@selector(applicationOpenURL:withApplication:sender:publicURLsOnly:animating:needsPermission:activationSettings:withResult:)]) {
				[self applicationOpenURL:url withApplication:nil sender:sender publicURLsOnly:NO animating:YES needsPermission:NO activationSettings:activationSettings withResult:nil];
			} else if ([self respondsToSelector:@selector(applicationOpenURL:publicURLsOnly:)]) {
				[self applicationOpenURL:url publicURLsOnly:NO];
			} else {
				[self openURL:url];
			}
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
				shouldBreadcrumb--;
			});
			suppressed--;
			return;
	}
}

// iOS 10

- (void)_openURLCore:(NSURL *)url display:(id)display animating:(BOOL)animating activationSettings:(id)activationSettings withResult:(id)resultHandler
{
	switch (BCApplyMappingAndOptionallyConsumeURL(&url, &display, nil, 0, activationSettings, resultHandler)) {
		case BCNoMappingApplied:
			return %orig();
		case BCMappedToUIElement:
			return;
		case BCMappedToNewApplication:
			suppressed++;
			shouldBreadcrumb++;
			if ([self respondsToSelector:@selector(applicationOpenURL:withApplication:publicURLsOnly:animating:needsPermission:activationSettings:withResult:)]) {
				[self applicationOpenURL:url withApplication:nil publicURLsOnly:NO animating:YES needsPermission:NO activationSettings:activationSettings withResult:nil];
			} else if ([self respondsToSelector:@selector(applicationOpenURL:publicURLsOnly:)]) {
				[self applicationOpenURL:url publicURLsOnly:NO];
			} else {
				[self openURL:url];
			}
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
				shouldBreadcrumb--;
			});
			suppressed--;
			return;
	}
}

%end

%hook SBMainDisplaySceneManager

- (BOOL)_shouldBreadcrumbApplication:(id)application withTransitionContext:(id)transitionContext
{
	return %orig() || shouldBreadcrumb;
}

%end

%hook SBHandMotionExtractor

- (void)extractHandMotionForActiveTouches:(void *)activeTouches count:(NSUInteger)count centroid:(CGPoint)centroid
{
	if (count && !isnan(centroid.x) && !isnan(centroid.y))
		lastTapCentroid = centroid;
	%orig;
}

%end

%end

%group App

%hook UIActionSheet

- (void)addButtonWithTitle:(NSString *)title
{
	%orig(BCReplaceSafariWordInText(title));
}

%end

%hook UIAlertView

- (void)addButtonWithTitle:(NSString *)title
{
	%orig(BCReplaceSafariWordInText(title));
}

- (void)setTitle:(NSString *)title
{
	%orig(BCReplaceSafariWordInText(title));
}

- (void)setMessage:(NSString *)message
{
	%orig(BCReplaceSafariWordInText(message));
}

%end

%hook UIButton

- (void)setTitle:(NSString *)title forState:(UIControlState)state
{
	%orig(BCReplaceSafariWordInText(title), state);
}

%end

%end

%hook MailAppController

-(void)openURL:(NSURL*)url options:(id)options completionHandler:(/*^block*/id)resultHandler
{
	switch (BCApplyMappingAndOptionallyConsumeURL(&url, NULL, nil, 0, 0, resultHandler)) {
		case BCNoMappingApplied:
			return %orig();
		case BCMappedToUIElement:
			return;
		case BCMappedToNewApplication:
			%orig(url, options, resultHandler);
			return;
	}
}

%end

%ctor
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	schemeMapping = [[NSDictionary alloc] initWithContentsOfFile:@"/Library/Application Support/BrowserChooser/mapping.plist"];
	%init;
	if (%c(SpringBoard)) {
		%init(SpringBoard);
	} else {
		%init(App);
	}
	[pool drain];
}
