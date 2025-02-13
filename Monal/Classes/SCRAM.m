//
//  SCRAM.m
//  monalxmpp
//
//  Created by Thilo Molitor on 05.08.22.
//  Copyright © 2022 monal-im.org. All rights reserved.
//

#include <arpa/inet.h>

#import <Foundation/Foundation.h>
#import "HelperTools.h"
#import "SCRAM.h"

@interface SCRAM ()
{
    BOOL _usingChannelBinding;
    NSString* _method;
    NSString* _username;
    NSString* _password;
    NSString* _nonce;
    NSString* _ssdpString;
    
    NSString* _clientFirstMessageBare;
    NSString* _gssHeader;
    
    NSString* _serverFirstMessage;
    uint32_t _iterationCount;
    NSData* _salt;
    
    NSString* _expectedServerSignature;
}
@end

//see these for intermediate test values:
//https://stackoverflow.com/a/32470299/3528174
//https://stackoverflow.com/a/29299946/3528174
@implementation SCRAM

//list supported mechanisms (highest security first!)
+(NSArray*) supportedMechanismsIncludingChannelBinding:(BOOL) include
{
    if(include)
        return @[@"SCRAM-SHA-512-PLUS", @"SCRAM-SHA-256-PLUS", @"SCRAM-SHA-1-PLUS", @"SCRAM-SHA-512", @"SCRAM-SHA-256", @"SCRAM-SHA-1"];
    return @[@"SCRAM-SHA-512", @"SCRAM-SHA-256", @"SCRAM-SHA-1"];
}

-(instancetype) initWithUsername:(NSString*) username password:(NSString*) password andMethod:(NSString*) method
{
    self = [super init];
    MLAssert([[[self class] supportedMechanismsIncludingChannelBinding:YES] containsObject:method], @"Unsupported SCRAM hash method!", (@{@"method": nilWrapper(method)}));
    _usingChannelBinding = [@"-PLUS" isEqualToString:[method substringFromIndex:method.length-5]];
    if(_usingChannelBinding)
        _method = [method substringWithRange:NSMakeRange(0, method.length-5)];
    else
        _method = method;
    _username = username;
    _password = password;
    _nonce = [NSUUID UUID].UUIDString;
    _ssdpString = nil;
    _finishedSuccessfully = NO;
    return self;
}

-(void) setSSDPMechanisms:(NSArray<NSString*>*) mechanisms andChannelBindingTypes:(NSArray<NSString*>* _Nullable) cbTypes
{
    MLAssert(!_finishedSuccessfully, @"SCRAM handler finished already!");
    DDLogVerbose(@"Creating SDDP string: %@\n%@", mechanisms, cbTypes);
    NSMutableString* ssdpString = [NSMutableString new];
    [ssdpString appendString:[[mechanisms sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
    if(cbTypes != nil)
    {
        [ssdpString appendString:@"|"];
        [ssdpString appendString:[[cbTypes sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
    }
    _ssdpString = [ssdpString copy];
    DDLogVerbose(@"SDDP string is now: %@", _ssdpString);
}

-(NSString*) clientFirstMessageWithChannelBinding:(NSString* _Nullable) channelBindingType
{
    MLAssert(!_finishedSuccessfully, @"SCRAM handler finished already!");
    if(channelBindingType == nil)
        _gssHeader = @"n,,";                                                                //not supported by us
    else if(!_usingChannelBinding)
        _gssHeader = @"y,,";                                                                //supported by us BUT NOT advertised by the server
    else
        _gssHeader = [NSString stringWithFormat:@"p=%@,,", channelBindingType];             //supported by us AND advertised by the server
    //the g attribute is a random grease to check if servers are rfc compliant (e.g. accept optional attributes)
    _clientFirstMessageBare = [NSString stringWithFormat:@"n=%@,r=%@,g=%@", [self quote:_username], _nonce, [NSUUID UUID].UUIDString];
    return [NSString stringWithFormat:@"%@%@", _gssHeader, _clientFirstMessageBare];
}

-(MLScramStatus) parseServerFirstMessage:(NSString*) str
{
    MLAssert(!_finishedSuccessfully, @"SCRAM handler finished already!");
    NSDictionary* msg = [self parseScramString:str];
    //server nonce MUST start with our client nonce
    if(![msg[@"r"] hasPrefix:_nonce])
        return MLScramStatusNonceError;
    //check for attributes not allowed per RFC
    for(NSString* key in msg)
        if([@"m" isEqualToString:key])
            return MLScramStatusUnsupportedMAttribute;
    _serverFirstMessage = str;
    _nonce = msg[@"r"];     //from now on use the full nonce
    _salt = [HelperTools dataWithBase64EncodedString:msg[@"s"]];
    _iterationCount = (uint32_t)[msg[@"i"] integerValue];
    //check if SSDP downgrade protection triggered, if provided
    if(msg[@"d"] != nil && _ssdpString != nil)
    {
        _ssdpSupported = YES;
        //calculate base64 encoded SSDP hash and compare it to server sent value
        NSString* ssdpHash =[HelperTools encodeBase64WithData:[self hash:[_ssdpString dataUsingEncoding:NSUTF8StringEncoding]]];
        if(![HelperTools constantTimeCompareAttackerString:msg[@"d"] withKnownString:ssdpHash])
            return MLScramStatusSSDPTriggered;
    }
    if(_iterationCount < 4096)
        return MLScramStatusIterationCountInsecure;
    return MLScramStatusOK;
}

//see https://stackoverflow.com/a/29299946/3528174
-(NSString*) clientFinalMessageWithChannelBindingData:(NSData* _Nullable) channelBindingData
{
    MLAssert(!_finishedSuccessfully, @"SCRAM handler finished already!");
    //calculate gss header with optional channel binding data
    NSMutableData* gssHeaderWithChannelBindingData = [NSMutableData new];
    [gssHeaderWithChannelBindingData appendData:[_gssHeader dataUsingEncoding:NSUTF8StringEncoding]];
    if(channelBindingData != nil)
        [gssHeaderWithChannelBindingData appendData:channelBindingData];
    
    NSData* saltedPassword = [self hashPasswordWithSalt:_salt andIterationCount:_iterationCount];
    
    //calculate clientKey (e.g. HMAC(SaltedPassword, "Client Key"))
    NSData* clientKey = [self hmacForKey:saltedPassword andData:[@"Client Key" dataUsingEncoding:NSUTF8StringEncoding]];
    
    //calculate storedKey (e.g. H(ClientKey))
    NSData* storedKey = [self hash:clientKey];
    
    //calculate authMessage (e.g. client-first-message-bare + "," + server-first-message + "," + client-final-message-without-proof)
    //the x attribute is a random grease to check if servers are rfc compliant (e.g. accept optional attributes)
    NSString* clientFinalMessageWithoutProof = [NSString stringWithFormat:@"c=%@,r=%@,x=%@", [HelperTools encodeBase64WithData:gssHeaderWithChannelBindingData], _nonce, [NSUUID UUID].UUIDString];
    NSString* authMessage = [NSString stringWithFormat:@"%@,%@,%@", _clientFirstMessageBare, _serverFirstMessage, clientFinalMessageWithoutProof];
    
    //calculate clientSignature (e.g. HMAC(StoredKey, AuthMessage))
    NSData* clientSignature = [self hmacForKey:storedKey andData:[authMessage dataUsingEncoding:NSUTF8StringEncoding]];
    
    //calculate clientProof (e.g. ClientKey XOR ClientSignature)
    NSData* clientProof = [HelperTools XORData:clientKey withData:clientSignature];
    
    //calculate serverKey (e.g. HMAC(SaltedPassword, "Server Key"))
    NSData* serverKey = [self hmacForKey:saltedPassword andData:[@"Server Key" dataUsingEncoding:NSUTF8StringEncoding]];
    
    //calculate _expectedServerSignature (e.g. HMAC(ServerKey, AuthMessage))
    _expectedServerSignature = [HelperTools encodeBase64WithData:[self hmacForKey:serverKey andData:[authMessage dataUsingEncoding:NSUTF8StringEncoding]]];
    
    //return client final message
    return [NSString stringWithFormat:@"%@,p=%@", clientFinalMessageWithoutProof, [HelperTools encodeBase64WithData:clientProof]];
}

-(MLScramStatus) parseServerFinalMessage:(NSString*) str
{
    MLAssert(!_finishedSuccessfully, @"SCRAM handler finished already!");
    NSDictionary* msg = [self parseScramString:str];
    //wrong v-value
    if(![HelperTools constantTimeCompareAttackerString:msg[@"v"] withKnownString:_expectedServerSignature])
        return MLScramStatusWrongServerProof;
    //server sent a SCRAM error
    if(msg[@"e"] != nil)
    {
        DDLogError(@"SCRAM error: '%@'", msg[@"e"]);
        return MLScramStatusServerError;
    }
    //everything was successful
    _finishedSuccessfully = YES;
    return MLScramStatusOK;
}

-(NSData*) hashPasswordWithSalt:(NSData*) salt andIterationCount:(uint32_t) iterationCount
{
    //calculate saltedPassword (e.g. Hi(Normalize(password), salt, i))
    uint32_t i = htonl(1);
    NSMutableData* salti = [NSMutableData dataWithData:salt];
    [salti appendData:[NSData dataWithBytes:&i length:sizeof(i)]];
    NSData* passwordData = [_password dataUsingEncoding:NSUTF8StringEncoding];
    NSData* saltedPasswordIntermediate = [self hmacForKey:passwordData andData:salti];
    NSData* saltedPassword = saltedPasswordIntermediate;
    for(long i = 1; i < iterationCount; i++)
    {
        saltedPasswordIntermediate = [self hmacForKey:passwordData andData:saltedPasswordIntermediate];
        saltedPassword = [HelperTools XORData:saltedPassword withData:saltedPasswordIntermediate];
    }
    return saltedPassword;
}

-(NSString*) method
{
    if(_usingChannelBinding)
        return [NSString stringWithFormat:@"%@-PLUS", _method];
    return _method;
}


-(NSData*) hmacForKey:(NSData*) key andData:(NSData*) data
{
    if([_method isEqualToString:@"SCRAM-SHA-1"])
        return [HelperTools sha1HmacForKey:key andData:data];
    if([_method isEqualToString:@"SCRAM-SHA-256"])
        return [HelperTools sha256HmacForKey:key andData:data];
    if([_method isEqualToString:@"SCRAM-SHA-512"])
        return [HelperTools sha512HmacForKey:key andData:data];
    NSAssert(NO, @"Unexpected error: unsupported SCRAM hash method!", (@{@"method": nilWrapper(_method)}));
    return nil;
}

-(NSData*) hash:(NSData*) data
{
    if([_method isEqualToString:@"SCRAM-SHA-1"])
        return [HelperTools sha1:data];
    if([_method isEqualToString:@"SCRAM-SHA-256"])
        return [HelperTools sha256:data];
    if([_method isEqualToString:@"SCRAM-SHA-512"])
        return [HelperTools sha512:data];
    NSAssert(NO, @"Unexpected error: unsupported SCRAM hash method!", (@{@"method": nilWrapper(_method)}));
    return nil;
}

-(NSDictionary* _Nullable) parseScramString:(NSString*) str
{
    NSMutableDictionary* retval = [NSMutableDictionary new];
    for(NSString* component in [str componentsSeparatedByString:@","])
    {
        NSString* attribute = [component substringToIndex:1];
        NSString* value = [component substringFromIndex:2];
        retval[attribute] = [self unquote:value];
    }
    return retval;
}

-(NSString*) quote:(NSString*) str
{
    //TODO: use proper saslprep to allow for non-ascii chars
    str = [str stringByReplacingOccurrencesOfString:@"=" withString:@"=3D"];
    str = [str stringByReplacingOccurrencesOfString:@"," withString:@"=2C"];
    return str;
}

-(NSString*) unquote:(NSString*) str
{
    //TODO: use proper saslprep to allow for non-ascii chars
    str = [str stringByReplacingOccurrencesOfString:@"=2C" withString:@","];
    str = [str stringByReplacingOccurrencesOfString:@"=3D" withString:@"="];
    return str;
}

+(void) SSDPXepOutput
{
    SCRAM* s = [[self alloc] initWithUsername:@"user" password:@"pencil" andMethod:@"SCRAM-SHA-1-PLUS"];
    
    s->_clientFirstMessageBare = @"n=user,r=12C4CD5C-E38E-4A98-8F6D-15C38F51CCC6";
    s->_gssHeader = @"p=tls-exporter,,";
    
    s->_serverFirstMessage = @"r=12C4CD5C-E38E-4A98-8F6D-15C38F51CCC6a09117a6-ac50-4f2f-93f1-93799c2bddf6,s=QSXCR+Q6sek8bf92,i=4096,d=dRc3RenuSY9ypgPpERowoaySQZY=";
    s->_nonce = @"12C4CD5C-E38E-4A98-8F6D-15C38F51CCC6a09117a6-ac50-4f2f-93f1-93799c2bddf6";
    s->_salt = [HelperTools dataWithBase64EncodedString:@"QSXCR+Q6sek8bf92"];
    s->_iterationCount = 4096;
    
    NSString* client_final_msg = [s clientFinalMessageWithChannelBindingData:[@"THIS IS FAKE CB DATA" dataUsingEncoding:NSUTF8StringEncoding]];
    DDLogError(@"client_final_msg: %@", client_final_msg);
    DDLogError(@"_expectedServerSignature: %@", s->_expectedServerSignature);
    
    [HelperTools flushLogsWithTimeout:0.250];
    exit(0);
}

@end
