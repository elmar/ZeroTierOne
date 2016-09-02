//
//  ServiceCom.m
//  ZeroTier One
//
//  Created by Grant Limberg on 8/4/16.
//  Copyright © 2016 ZeroTier, Inc. All rights reserved.
//

#import "ServiceCom.h"
#import "AuthtokenCopy.h"
#import "Network.h"
#import "NodeStatus.h"
@import AppKit;

@interface ServiceCom (Private)

- (NSString*)key;

@end

@implementation ServiceCom

+ (ServiceCom*)sharedInstance {
    static ServiceCom *sc = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sc = [[ServiceCom alloc] init];
    });
    return sc;
}

- (id)init
{
    self = [super init];
    if(self) {
        baseURL = @"http://localhost:9993";
        session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
        _isQuitting = NO;
    }

    return self;
}

- (NSString*)key:(NSError* __autoreleasing *)err
{
    static NSString *k = nil;

    if (k == nil) {
        NSError *error = nil;
        NSURL *appSupportDir = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:false error:&error];

        if (error) {
            NSLog(@"Error: %@", error);
            return @"";
        }

        appSupportDir = [[appSupportDir URLByAppendingPathComponent:@"ZeroTier"] URLByAppendingPathComponent:@"One"];
        NSURL *authtokenURL = [appSupportDir URLByAppendingPathComponent:@"authtoken.secret"];

        if ([[NSFileManager defaultManager] fileExistsAtPath:[authtokenURL path]]) {
            k = [NSString stringWithContentsOfURL:authtokenURL
                                         encoding:NSUTF8StringEncoding
                                            error:&error];

            if (error) {
                NSLog(@"Error: %@", error);
                k = nil;
                *err = error;
                return @"";
            }
        }
        else {
            NSURL *sysAppSupportDir = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSSystemDomainMask appropriateForURL:nil create:false error:nil];

            sysAppSupportDir = [[sysAppSupportDir URLByAppendingPathComponent:@"ZeroTier"] URLByAppendingPathComponent:@"One"];
            NSURL *sysAuthtokenURL = [sysAppSupportDir URLByAppendingPathComponent:@"authtoken.secret"];

            if(![[NSFileManager defaultManager] fileExistsAtPath:[sysAuthtokenURL path]]) {

            }

            [[NSFileManager defaultManager] createDirectoryAtURL:appSupportDir
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&error];

            if (error) {
                NSLog(@"Error: %@", error);
                *err = error;
                k = nil;
                return @"";
            }

            AuthorizationRef authRef;
            OSStatus status = AuthorizationCreate(nil, nil, kAuthorizationFlagDefaults, &authRef);

            if (status != errAuthorizationSuccess) {
                NSLog(@"Authorization Failed! %d", status);

                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't create AuthorizationRef", nil),
                                           };
                *err = [NSError errorWithDomain:@"com.zerotier.one" code:-1 userInfo:userInfo];

                return @"";
            }

            AuthorizationItem authItem;
            authItem.name = kAuthorizationRightExecute;
            authItem.valueLength = 0;
            authItem.flags = 0;

            AuthorizationRights authRights;
            authRights.count = 1;
            authRights.items = &authItem;

            AuthorizationFlags authFlags = kAuthorizationFlagDefaults |
                                           kAuthorizationFlagInteractionAllowed |
                                           kAuthorizationFlagPreAuthorize |
                                           kAuthorizationFlagExtendRights;

            status = AuthorizationCopyRights(authRef, &authRights, nil, authFlags, nil);

            if (status != errAuthorizationSuccess) {
                NSLog(@"Authorization Failed! %d", status);
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't copy authorization rights", nil),
                                           };
                *err = [NSError errorWithDomain:@"com.zerotier.one" code:-1 userInfo:userInfo];
                return @"";
            }

            NSString *localKey = getAdminAuthToken(authRef);
            AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);

            if (localKey != nil && [localKey lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 0) {
                k = localKey;

                [localKey writeToURL:authtokenURL
                          atomically:YES
                            encoding:NSUTF8StringEncoding
                               error:&error];

                if (error) {
                    NSLog(@"Error writing token to disk: %@", error);
                    *err = error;
                }
            }
        }
    }

    if (k == nil) {
        NSDictionary *userInfo = @{
                                   NSLocalizedDescriptionKey: NSLocalizedString(@"Unknown error finding authorization key", nil),
                                   };
        *err = [NSError errorWithDomain:@"com.zerotier.one" code:-1 userInfo:userInfo];

        return @"";
    }

    return k;
}

- (void)getNetworklist:(void (^)(NSArray<Network *> *))completionHandler error:(NSError *__autoreleasing*)error
{
    NSString* key = [self key:error];
    if(*error) {
        return;
    }

    NSString *urlString = [[baseURL stringByAppendingString:@"/network?auth="] stringByAppendingString:key];

    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDataTask *task =
    [session dataTaskWithURL:url
           completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable err) {

               if (err) {
                   [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                       NSAlert *alert = [NSAlert alertWithError:err];
                       alert.alertStyle = NSCriticalAlertStyle;
                       [alert addButtonWithTitle:@"Quit"];
                       [alert addButtonWithTitle:@"Retry"];

                       NSModalResponse res;
                       if (!_isQuitting) {
                           res = [alert runModal];
                       }
                       else {
                           return;
                       }

                       if(res == NSAlertFirstButtonReturn) {
                           [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                           _isQuitting = YES;
                       }
                   }];
                   return;
               }

               NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
               NSInteger status = [httpResponse statusCode];

               NSError *err2;

               if (status == 200) {
                   NSArray *json = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:0
                                                                     error:&err2];
                   if (err) {
                       NSLog(@"Error fetching network list: %@", err2);

                       [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                           NSAlert *alert = [NSAlert alertWithError:err2];
                           alert.alertStyle = NSCriticalAlertStyle;
                           [alert addButtonWithTitle:@"Quit"];
                           [alert addButtonWithTitle:@"Retry"];

                           NSModalResponse res;
                           if (!_isQuitting) {
                               res = [alert runModal];
                           }
                           else {
                               return;
                           }

                           if(res == NSAlertFirstButtonReturn) {
                               _isQuitting = YES;
                               [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                           }
                       }];
                       return;
                   }

                   NSMutableArray<Network*> *networks = [[NSMutableArray<Network*> alloc] init];
                   for(NSDictionary *dict in json) {
                       [networks addObject:[[Network alloc] initWithJsonData:dict]];
                   }

                   completionHandler(networks);
               }
    }];
    [task resume];
}

- (void)getNodeStatus:(void (^)(NodeStatus*))completionHandler error:(NSError*__autoreleasing*)error
{
    NSString *key = [self key:error];
    if(*error) {
        return;
    }

    NSString *urlString = [[baseURL stringByAppendingString:@"/status?auth="] stringByAppendingString:key];

    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDataTask *task =
    [session dataTaskWithURL:url
           completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable err) {

               if(err) {
                   [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                       NSAlert *alert = [NSAlert alertWithError:err];
                       alert.alertStyle = NSCriticalAlertStyle;
                       [alert addButtonWithTitle:@"Quit"];
                       [alert addButtonWithTitle:@"Retry"];

                       NSModalResponse res;
                       if (!_isQuitting) {
                           res = [alert runModal];
                       }
                       else {
                           return;
                       }

                       if(res == NSAlertFirstButtonReturn) {
                           [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                           _isQuitting = YES;
                       }
                   }];
                   return;
               }

               NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
               NSInteger status = [httpResponse statusCode];

               NSError *err2;
               if(status == 200) {
                   NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                        options:0
                                                                          error:&err2];

                   if(err2) {
                       NSLog(@"Error fetching node status: %@", err2);
                       [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                           NSAlert *alert = [NSAlert alertWithError:err2];
                           alert.alertStyle = NSCriticalAlertStyle;
                           [alert addButtonWithTitle:@"Quit"];
                           [alert addButtonWithTitle:@"Retry"];

                           NSModalResponse res;
                           if (!_isQuitting) {
                               res = [alert runModal];
                           }
                           else {
                               return;
                           }

                           if(res == NSAlertFirstButtonReturn) {
                               [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                               _isQuitting = YES;
                           }
                       }];
                       return;
                   }

                   NodeStatus *status = [[NodeStatus alloc] initWithJsonData:json];

                   completionHandler(status);
               }
           }];
    [task resume];
}

- (void)joinNetwork:(NSString*)networkId allowManaged:(BOOL)allowManaged allowGlobal:(BOOL)allowGlobal allowDefault:(BOOL)allowDefault error:(NSError *__autoreleasing*)error
{
    NSString *key = [self key:error];
    if(*error) {
        return;
    }

    NSString *urlString = [[[[baseURL stringByAppendingString:@"/network/"]
                             stringByAppendingString:networkId]
                            stringByAppendingString:@"?auth="]
                           stringByAppendingString:key];

    NSURL *url = [NSURL URLWithString:urlString];

    NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
    [jsonDict setObject:[NSNumber numberWithBool:allowManaged] forKey:@"allowManaged"];
    [jsonDict setObject:[NSNumber numberWithBool:allowGlobal] forKey:@"allowGlobal"];
    [jsonDict setObject:[NSNumber numberWithBool:allowDefault] forKey:@"allowDefault"];

    NSError *err = nil;

    NSData *json = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                   options:0
                                                     error:&err];

    if(err) {
        NSLog(@"Error creating json data: %@", err);
        *error = err;
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = json;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSURLSessionDataTask *task =
    [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable err) {
        if(err) {
            NSLog(@"Error posting join request: %@", err);
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                NSAlert *alert = [NSAlert alertWithError:err];
                alert.alertStyle = NSCriticalAlertStyle;
                [alert addButtonWithTitle:@"Quit"];
                [alert addButtonWithTitle:@"Retry"];

                NSModalResponse res;
                if (!_isQuitting) {
                    res = [alert runModal];
                }
                else {
                    return;
                }

                if(res == NSAlertFirstButtonReturn) {
                    [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                    _isQuitting = YES;
                }
            }];
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        NSInteger status = [httpResponse statusCode];

        if(status == 200) {
            NSLog(@"join ok");
        }
        else {
            NSLog(@"join error: %ld", (long)status);
        }
    }];
    [task resume];
}

- (void)leaveNetwork:(NSString*)networkId error:(NSError*__autoreleasing*)error
{
    NSString *key = [self key:error];
    if(*error) {
        return;
    }

    NSString *urlString = [[[[baseURL stringByAppendingString:@"/network/"]
                             stringByAppendingString:networkId]
                            stringByAppendingString:@"?auth="]
                           stringByAppendingString:key];

    NSURL *url = [NSURL URLWithString:urlString];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"DELETE";

    NSURLSessionDataTask *task =
    [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable err) {
        if(err) {
            NSLog(@"Error posting delete request: %@", err);
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                NSAlert *alert = [NSAlert alertWithError:err];
                alert.alertStyle = NSCriticalAlertStyle;
                [alert addButtonWithTitle:@"Quit"];
                [alert addButtonWithTitle:@"Retry"];

                NSModalResponse res;
                if (!_isQuitting) {
                    res = [alert runModal];
                }
                else {
                    return;
                }

                if(res == NSAlertFirstButtonReturn) {
                    [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                    _isQuitting = YES;
                }
            }];
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        NSInteger status = httpResponse.statusCode;

        if(status == 200) {
            NSLog(@"leave ok");
        }
        else {
            NSLog(@"leave error: %ld", status);
        }
    }];
    [task resume];
}

@end
