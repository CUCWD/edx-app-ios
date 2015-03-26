//
//  OEXAuthentication.m
//  edXVideoLocker
//
//  Created by Jotiram Bhagat on 25/06/14.
//  Copyright (c) 2014 edX. All rights reserved.
//

#import "OEXAuthentication.h"

#import "NSDictionary+OEXEncoding.h"
#import "NSMutableDictionary+OEXSafeAccess.h"
#import "NSString+OEXFormatting.h"

#import "OEXAppDelegate.h"
#import "OEXConfig.h"
#import "OEXExternalAuthProvider.h"
#import "OEXFacebookAuthProvider.h"
#import "OEXFBSocial.h"
#import "OEXGoogleAuthProvider.h"
#import "OEXGoogleSocial.h"
#import "OEXHTTPStatusCodes.h"
#import "OEXInterface.h"
#import "OEXNetworkConstants.h"
#import "OEXUserDetails.h"
#import "OEXSession.h"

NSString* const facebook_login_endpoint = @"facebook";
NSString* const google_login_endpoint = @"google-oauth2";

typedef void (^ OEXSocialLoginCompletionHandler)(NSString* accessToken, NSError* error);

@interface OEXAuthentication ()
@property(nonatomic, strong) OEXAccessToken* edxToken;
@end

typedef void (^OEXNSDataTaskRequestHandler)(NSData* data, NSURLResponse* response, NSError* error) ;

// All our NSURLResponses are HTTP responses, so this wraps up the cast into one place
OEXNSDataTaskRequestHandler OEXWrapURLCompletion(OEXURLRequestHandler completion) {
    return ^(NSData* data, NSURLResponse* response, NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Hacky - We should be using a networking library that manages this for us
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            completion(data, (NSHTTPURLResponse*)response, error);
        });
    };
}

@implementation OEXAuthentication

//This method gets called when user try to login with username password
+ (void)requestTokenWithUser:(NSString* )username password:(NSString* )password completionHandler:(OEXURLRequestHandler)completionBlock {
    NSString* body = [self plainTextAuthorizationHeaderForUserName:username password:password];
    NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [OEXConfig sharedConfig].apiHostURL, AUTHORIZATION_URL]]];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:sessionConfig];
    [[session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*) response;
            if(httpResp.statusCode == OEXHTTPStatusCode200OK) {
                NSError* error;
                NSDictionary* dictionary = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
                OEXAccessToken* token = [[OEXAccessToken alloc] initWithTokenDetails:dictionary];
                [OEXAuthentication handleSuccessfulLoginWithToken:token completionHandler:completionBlock];
            }
            else {
                completionBlock(data, httpResp, error);
            }
        }]resume];
}

+ (void)executePOSTRequestWithPath:(NSString*)path parameters:(NSDictionary*)parameters completion:(OEXURLRequestHandler)completion {
    NSURL* hostURL = [NSURL URLWithString:[[OEXConfig sharedConfig] apiHostURL]];
    NSURL* endpoint = [NSURL URLWithString:path relativeToURL:hostURL];
    
    NSString* body = [parameters oex_stringByUsingFormEncoding];
    NSData* bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL:endpoint];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:bodyData];
    [request addValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request addValue:@"application/json" forHTTPHeaderField:@"Accept"];
    
    NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:sessionConfig];
    [[session dataTaskWithRequest:request completionHandler:OEXWrapURLCompletion(completion)] resume];
}

+ (void)requestTokenWithProvider:(id <OEXExternalAuthProvider>)provider externalToken:(NSString *)token completion:(OEXURLRequestHandler)completionBlock {
    
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    
    NSMutableDictionary* parameters = [[NSMutableDictionary alloc] init];
    [parameters safeSetObject:token forKey:@"access_token"];
    [parameters safeSetObject:[[OEXConfig sharedConfig] oauthClientID] forKey:@"client_id"];
    NSString* path = [NSString oex_stringWithFormat:URL_EXCHANGE_TOKEN parameters:@{@"backend" : provider.backendName}];
    
    [self executePOSTRequestWithPath:path parameters:parameters completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if(!error) {
            NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*) response;
            if(httpResp.statusCode == 200) {
                NSError* error;
                NSDictionary* dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                NSAssert(error == nil, @"Invalid JSON from server");
                OEXAccessToken* token = [[OEXAccessToken alloc] initWithTokenDetails:dictionary];
                [self handleSuccessfulLoginWithToken:token completionHandler:completionBlock];
                return;
            }
            else if(httpResp.statusCode == 401) {
                error = [NSError errorWithDomain:@"Not valid user" code:401 userInfo:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObject:@"You are not associated with edx please signup up from website"] forKeys:[NSArray arrayWithObject:@"failed"]]];
            }
        }
        OEXWrapURLCompletion(completionBlock)(data, response, error);
    }];
}

+ (void)resetPasswordWithEmailId:(NSString*)email completionHandler:(OEXURLRequestHandler)completionBlock {
    NSMutableDictionary* parameters = [[NSMutableDictionary alloc] init];
    [parameters safeSetObject:email forKey:@"email"];
    [self executePOSTRequestWithPath:URL_RESET_PASSWORD parameters:parameters completion:completionBlock];
}

// This retuns header for password authentication method
+ (NSString*)plainTextAuthorizationHeaderForUserName:(NSString*)userName password:(NSString*)password {
    NSString* clientID = [[OEXConfig sharedConfig] oauthClientID];
    NSString* clientSecret = [[OEXConfig sharedConfig] oauthClientSecret];

    return [@{
                @"client_id" : clientID,
                @"client_secret" : clientSecret,
                @"grant_type" : @"password",
                @"username" : userName,
                @"password" : password
            } oex_stringByUsingFormEncoding];
}

//// This methods is used to get user details when user access token is available
- (void)getUserDetailsWith:(OEXAccessToken*)edxToken completionHandler:(OEXURLRequestHandler)completionBlock {
    self.edxToken = edxToken;

    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:self
                                                     delegateQueue:nil];
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [OEXConfig sharedConfig].apiHostURL, URL_GET_USER_INFO]]];
    NSString* authValue = [NSString stringWithFormat:@"%@ %@", edxToken.tokenType, edxToken.accessToken];
    [request setValue:authValue forHTTPHeaderField:@"Authorization"];
    NSURLSessionDataTask* task = [session dataTaskWithRequest:request completionHandler:OEXWrapURLCompletion(completionBlock)];
    [task resume];
}

// Returns authentication header for every authenticated webservice call
+ (NSString*)authHeaderForApiAccess {
    OEXSession* session = [OEXSession activeSession];
    if(session.edxToken.accessToken && session.edxToken.tokenType) {
        NSString* header = [NSString stringWithFormat:@"%@ %@", session.edxToken.tokenType, session.edxToken.accessToken];
        return header;
    }
    else if(session.edxToken.accessToken) {
        NSString* header = [NSString stringWithFormat:@"%@", session.edxToken.accessToken];
        return header;
    }
    else {
        return nil;
    }
}

#pragma mark NSURLSession Delegate

- (void)            URLSession:(NSURLSession*)session
                          task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)redirectResponse
                    newRequest:(NSURLRequest*)request
             completionHandler:(void (^)(NSURLRequest*))completionHandler {
    NSMutableURLRequest* mutablerequest = [request mutableCopy];
    NSString* authValue = [NSString stringWithFormat:@"%@ %@", self.edxToken.tokenType, self.edxToken.accessToken];
    [mutablerequest setValue:authValue forHTTPHeaderField:@"Authorization"];

    completionHandler([mutablerequest copy]);
}

#pragma mark Social Login Methods

+ (void)loginWithGoogle:(OEXSocialLoginCompletionHandler)handler {
    [[OEXGoogleSocial sharedInstance] login:handler];
}

+ (void)loginWithFacebook:(OEXSocialLoginCompletionHandler)handler {
    [[OEXFBSocial sharedInstance] login:handler];
}

+ (void)socialLoginWith:(OEXSocialLoginType)loginType completionHandler:(OEXURLRequestHandler)handler {
    switch(loginType) {
        case OEXFacebookLogin: {
            [OEXAuthentication loginWithFacebook:^(NSString* accessToken, NSError* error) {
                if(accessToken) {
                    [OEXAuthentication authenticateWithAccessToken:accessToken loginType:OEXFacebookLogin completionHandler:handler];
                }
                else {
                    handler(nil, nil, error);
                }
            }];
            break;
        }
        case OEXGoogleLogin: {
            [OEXAuthentication loginWithGoogle:^(NSString* accessToken, NSError* error) {
                if(accessToken) {
                    [OEXAuthentication authenticateWithAccessToken:accessToken loginType:OEXGoogleLogin completionHandler:handler];
                }
                else {
                    handler(nil, nil, error);
                }
            }];
            break;
        }

        default: {
            handler(nil, nil, nil);
            break;
        }
    }
}

+ (void)authenticateWithAccessToken:(NSString*)token loginType:(OEXSocialLoginType)loginType completionHandler:(void (^)(NSData* userdata, NSHTTPURLResponse* userresponse, NSError* usererror))completion {
    id <OEXExternalAuthProvider> provider = nil;
    switch (loginType) {
        case OEXFacebookLogin:
            provider = [[OEXFacebookAuthProvider alloc] init];
            break;
        case OEXGoogleLogin:
            provider = [[OEXGoogleAuthProvider alloc] init];
            break;
    }
    [self requestTokenWithProvider:provider externalToken:token completion:completion];
}

+ (void)handleSuccessfulLoginWithToken:(OEXAccessToken*)edxToken completionHandler:(OEXURLRequestHandler)completionHandler {
    OEXAuthentication* edxAuth = [[OEXAuthentication alloc] init];
    [edxAuth getUserDetailsWith:edxToken completionHandler:^(NSData* userdata, NSURLResponse* userresponse, NSError* usererror) {
        NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*) userresponse;
        if(httpResp.statusCode == 200) {
            NSDictionary* dictionary = [NSJSONSerialization JSONObjectWithData:userdata options:kNilOptions error:nil];
            OEXUserDetails* userDetails = [[OEXUserDetails alloc] initWithUserDictionary:dictionary];
            [OEXSession createSessionWithAccessToken:edxToken andUserDetails:userDetails];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
                OEXWrapURLCompletion(completionHandler)(userdata, userresponse, usererror);
            });
    }];
}

+ (void)registerUserWithParameters:(NSDictionary*)parameters completionHandler:(OEXURLRequestHandler)handler {
    NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [OEXConfig sharedConfig].apiHostURL, SIGN_UP_URL]]];
    [request setHTTPMethod:@"POST"];

    NSString* postString = [parameters oex_stringByUsingFormEncoding];
    [request setHTTPBody:[postString dataUsingEncoding:NSUTF8StringEncoding]];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:sessionConfig delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
    [[session dataTaskWithRequest:request completionHandler:OEXWrapURLCompletion(handler)]resume];
}

@end
