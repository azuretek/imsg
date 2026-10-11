#pragma mark - Inbound Event Observers

/// Register NSNotificationCenter observers that translate IMCore notifications
/// into JSON-lines events on `.imsg-events.jsonl`. These power
/// `imsg watch --bb-events` for live typing/alias-removal indicators.
// Incoming typing (issue: no started-typing ever reached the event log on macOS 26).
// IMChatItemsDidChangeNotification no longer carries the inserted items in its
// userInfo there, so the observer below never sees a typing item. Messages hands
// every incoming item, a typing indicator included, to
// -[IMChat _handleIncomingItem:]; the bridge wraps that method and reports
// started-typing / stopped-typing from the item itself, logging only the item's
// class, never its content.

static void reportIncomingTypingItem(id chat, id item) {
    if (!item) return;
    BOOL typing = NO, cancel = NO, fromMe = NO;
    if ([item respondsToSelector:@selector(isTypingMessage)]) {
        typing = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isTypingMessage));
    }
    if ([item respondsToSelector:@selector(isCancelTypingMessage)]) {
        cancel = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isCancelTypingMessage));
    }
    if (!typing && !cancel) return;
    if ([item respondsToSelector:@selector(isFromMe)]) {
        fromMe = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isFromMe));
    }
    if (fromMe) return;
    // The variants call one another, so one item reaches this more than once; it is reported once.
    static __weak id lastItem = nil;
    static BOOL lastCancel = NO;
    @synchronized ([NSObject class]) {
        if (lastItem == item && lastCancel == cancel) return;
        lastItem = item;
        lastCancel = cancel;
    }
    NSString *chatGuid = nil;
    if (chat && [chat respondsToSelector:@selector(guid)]) {
        chatGuid = [chat performSelector:@selector(guid)];
    }
    debugLog(@"incoming typing: %@ cancel=%d", NSStringFromClass([item class]), cancel);
    appendEvent(@{
        @"event": cancel ? @"stopped-typing" : @"started-typing",
        @"data": @{ @"chatGuid": chatGuid ?: @"" }
    });
}

// Messages hands an incoming item to whichever of these variants this macOS uses (on macOS 26 the longest), so each
// one present is wrapped. Each is installed only when its type encoding is a BOOL result with an object and BOOL
// arguments, the shape the wrapper calls it with; any other shape is logged and left alone.
static IMP gOrigIncoming[5];

static BOOL imsgIncoming1(id self, SEL _cmd, id item) {
    BOOL r = ((BOOL (*)(id, SEL, id))gOrigIncoming[0])(self, _cmd, item);
    @try { reportIncomingTypingItem(self, item); } @catch (__unused id e) {}
    return r;
}
static BOOL imsgIncoming2(id self, SEL _cmd, id item, BOOL a) {
    BOOL r = ((BOOL (*)(id, SEL, id, BOOL))gOrigIncoming[1])(self, _cmd, item, a);
    @try { reportIncomingTypingItem(self, item); } @catch (__unused id e) {}
    return r;
}
static BOOL imsgIncoming3(id self, SEL _cmd, id item, BOOL a, BOOL b) {
    BOOL r = ((BOOL (*)(id, SEL, id, BOOL, BOOL))gOrigIncoming[2])(self, _cmd, item, a, b);
    @try { reportIncomingTypingItem(self, item); } @catch (__unused id e) {}
    return r;
}
static BOOL imsgIncoming4(id self, SEL _cmd, id item, BOOL a, BOOL b, BOOL c) {
    BOOL r = ((BOOL (*)(id, SEL, id, BOOL, BOOL, BOOL))gOrigIncoming[3])(self, _cmd, item, a, b, c);
    @try { reportIncomingTypingItem(self, item); } @catch (__unused id e) {}
    return r;
}
static BOOL imsgIncoming5(id self, SEL _cmd, id item, BOOL a, BOOL b, BOOL c, BOOL d) {
    BOOL r = ((BOOL (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL))gOrigIncoming[4])(self, _cmd, item, a, b, c, d);
    @try { reportIncomingTypingItem(self, item); } @catch (__unused id e) {}
    return r;
}

static void installIncomingTypingHook(void) {
    Class chatClass = NSClassFromString(@"IMChat");
    if (!chatClass) return;
    const char *sels[5] = {
        "_handleIncomingItem:",
        "_handleIncomingItem:updateRecipient:",
        "_handleIncomingItem:updateRecipient:suppressNotification:",
        "_handleIncomingItem:updateRecipient:suppressNotification:updateReplyCounts:",
        "_handleIncomingItem:updateRecipient:suppressNotification:updateReplyCounts:messageComingFromStorage:",
    };
    IMP impls[5] = { (IMP)imsgIncoming1, (IMP)imsgIncoming2, (IMP)imsgIncoming3, (IMP)imsgIncoming4, (IMP)imsgIncoming5 };
    for (int i = 0; i < 5; i++) {
        if (gOrigIncoming[i]) continue;
        Method m = class_getInstanceMethod(chatClass, sel_registerName(sels[i]));
        if (!m) continue;
        const char *enc = method_getTypeEncoding(m);
        NSString *shape = [[NSString stringWithUTF8String:enc ?: ""] stringByTrimmingCharactersInSet:[NSCharacterSet decimalDigitCharacterSet]];
        NSString *clean = [[shape componentsSeparatedByCharactersInSet:[NSCharacterSet decimalDigitCharacterSet]] componentsJoinedByString:@""];
        NSMutableString *want = [NSMutableString stringWithString:@"B@:@"];
        for (int k = 0; k < i; k++) [want appendString:@"B"];
        if (![clean isEqualToString:want]) {
            debugLog(@"incoming typing: %s has shape %@, not hooked", sels[i], clean);
            continue;
        }
        gOrigIncoming[i] = method_setImplementation(m, impls[i]);
        debugLog(@"incoming typing: hooked -[IMChat %s]", sels[i]);
    }
}

// The event log exists from the start, so imsg rpc advertises bridge.events.subscribe
// (it requires a readable regular file) before the first event is ever written.
static void ensureEventsFile(void) {
    initFilePaths();
    if (!kEventsFile) return;
    int fd = open(kEventsFile.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) close(fd);
}

static void registerEventObservers(void) {
    ensureEventsFile();
    installIncomingTypingHook();
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // IMChatItemsDidChange: fires whenever a chat's item list shifts. We
    // inspect the userInfo to spot inserted IMTypingChatItem instances and
    // emit started-typing / stopped-typing events.
    [nc addObserverForName:@"IMChatItemsDidChangeNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @autoreleasepool {
            id chat = note.object;
            NSString *chatGuid = nil;
            if (chat && [chat respondsToSelector:@selector(guid)]) {
                chatGuid = [chat performSelector:@selector(guid)];
            }
            NSDictionary *userInfo = note.userInfo;
            NSArray *inserted = userInfo[@"__kIMChatValueKey"]
                              ?: userInfo[@"inserted"];
            if (![inserted isKindOfClass:[NSArray class]]) return;
            for (id item in inserted) {
                NSString *cls = NSStringFromClass([item class]);
                if ([cls containsString:@"TypingChatItem"]) {
                    BOOL isCancel = NO;
                    if ([item respondsToSelector:@selector(isCancelTypingMessage)]) {
                        isCancel = ((BOOL (*)(id, SEL))objc_msgSend)(item,
                            @selector(isCancelTypingMessage));
                    }
                    appendEvent(@{
                        @"event": isCancel ? @"stopped-typing" : @"started-typing",
                        @"data": @{ @"chatGuid": chatGuid ?: @"" }
                    });
                }
            }
        }
    }];

    // Account aliases removed (e.g., user removed an iMessage email).
    [nc addObserverForName:@"__kIMAccountAliasesRemovedNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        appendEvent(@{
            @"event": @"aliases-removed",
            @"data": note.userInfo ?: @{}
        });
    }];

    NSLog(@"[imsg-bridge] Event observers registered");
}

