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
static IMP gOrigHandleIncomingItem = NULL;

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

static BOOL imsgHandleIncomingItem(id self, SEL _cmd, id item) {
    BOOL handled = ((BOOL (*)(id, SEL, id))gOrigHandleIncomingItem)(self, _cmd, item);
    @try {
        reportIncomingTypingItem(self, item);
    } @catch (__unused id e) {
    }
    return handled;
}

static void installIncomingTypingHook(void) {
    if (gOrigHandleIncomingItem) return;
    Class chatClass = NSClassFromString(@"IMChat");
    SEL sel = NSSelectorFromString(@"_handleIncomingItem:");
    Method m = chatClass ? class_getInstanceMethod(chatClass, sel) : NULL;
    if (!m) {
        debugLog(@"incoming typing: -[IMChat _handleIncomingItem:] not found");
        return;
    }
    gOrigHandleIncomingItem = method_setImplementation(m, (IMP)imsgHandleIncomingItem);
    debugLog(@"incoming typing: hooked -[IMChat _handleIncomingItem:]");
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

