//
//  YMServer.m
//  YMServerDemo
//
//  Created by long on 3/21/16.
//  Copyright © 2016 long. All rights reserved.
//

#import "YMServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#define CHAT_SERVER_PORT  8888


static void SocketConnectionAcceptedCallBack(CFSocketRef socket,
                                            CFSocketCallBackType type,
                                             CFDataRef address,
                                             const void *data, void *info){
    YMServer *theChatServer = (__bridge YMServer *)info;
    if (kCFSocketAcceptCallBack == type) {
        // 摘自kCFSocketAcceptCallBack的文档，New connections will be automatically accepted and the callback is called with the data argument being a pointer to a CFSocketNativeHandle of the child socket. This callback is usable only with listening sockets.
        CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;
        // create the read and write streams for the connection to the other process
        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle,
                                     &readStream, &writeStream);
        if(NULL != readStream && NULL != writeStream) {
            CFReadStreamSetProperty(readStream,
                                    kCFStreamPropertyShouldCloseNativeSocket,
                                    kCFBooleanTrue);
            CFWriteStreamSetProperty(writeStream,
                                     kCFStreamPropertyShouldCloseNativeSocket,
                                     kCFBooleanTrue);
            NSInputStream *inputStream = (__bridge NSInputStream *)readStream;//toll-free bridging
            NSOutputStream *outputStream = (__bridge NSOutputStream *)writeStream;//toll-free bridging
            inputStream.delegate = theChatServer;
            [inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            [inputStream open];
            outputStream.delegate = theChatServer;
            [outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            [outputStream open];
//            Client *aClient = [[Client alloc] init];
//            aClient.inputStream = inputStream;
//            aClient.outputStream = outputStream;
//            aClient.sock_fd = nativeSocketHandle;
//            [theChatServer.clients setValue:aClient
//                                     forKey:[NSString stringWithFormat:@"%d",inputStream]];
            NSLog(@"有新客户端(sock_fd=%d)加入",nativeSocketHandle);
        } else {
            close(nativeSocketHandle);
        }
        if (readStream) CFRelease(readStream);
        if (writeStream) CFRelease(writeStream);
    }
}

static void FileDescriptorCallBack(CFFileDescriptorRef f,
                                   CFOptionFlags callBackTypes,
                                   void *info){
    int fd = CFFileDescriptorGetNativeDescriptor(f);
    YMServer *theChatServer = (__bridge YMServer *)info;
    if (fd == STDIN_FILENO) {
        NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] availableData];
        NSString *inputString = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
        NSLog(@"准备发送消息:%@",inputString);
//        for (Client *client in [theChatServer.clients allValues]) {
//            [client.outputStream write:[inputData bytes] maxLength:[inputData length]];
//        }
        //处理完数据之后必须重新Enable 回调函数
        CFFileDescriptorEnableCallBacks(f,kCFFileDescriptorReadCallBack);
    }
}

@interface YMServer (){
    CFSocketRef _socket;

}

@property (nonatomic, assign) NSInteger port;
@end
@implementation YMServer

- (BOOL)run:(NSError **)error{
    BOOL successful = YES;
    
    CFSocketContext socketCtxt = {0, (__bridge void *)(self), NULL, NULL, NULL};
    
    _socket = CFSocketCreate(kCFAllocatorDefault,// 为新对象分配内存，可以为nil
                             PF_INET,    // 协议族，如果为0或者负数，则默认为PF_INET
                             SOCK_STREAM, // 套接字类型，如果协议族为PF_INET,则它会默认为SOCK_STREAM
                             IPPROTO_TCP, // 套接字协议，如果协议族是PF_INET且协议是0或者负数，它会默认为IPPROTO_TCP
                             kCFSocketAcceptCallBack, // 触发回调函数的socket消息类型，具体见Callback Types
                             (CFSocketCallBack)&SocketConnectionAcceptedCallBack,// 上面情况下触发的回调函数
                             &socketCtxt); // // 一个持有CFSocket结构信息的对象，可以为nil
    
    if (NULL == _socket) {
        if ( nil != error) {
//            *error = [[NSError alloc]
//                      initWithDomain:ServerErrorDomain
//                      code:kServerNoSocketsAvailable
//                      userInfo:nil];
            successful = NO;
        }
    }
    
    if (YES == successful) {
        // enable address reuse
        int  yes = 1;
        setsockopt(CFSocketGetNative(_socket),
                   SOL_SOCKET, SO_REUSEADDR,
                   (void *)&yes, sizeof(yes));
        uint8_t packetSize = 128;
        setsockopt(CFSocketGetNative(_socket),
                   SOL_SOCKET, SO_SNDBUF,
                   (void *)&packetSize, sizeof(packetSize));
        setsockopt(CFSocketGetNative(_socket),
                   SOL_SOCKET, SO_RCVBUF,
                   (void *)&packetSize, sizeof(packetSize));
        struct sockaddr_in addr4;
        memset(&addr4, 0, sizeof(addr4));
        addr4.sin_len = sizeof(addr4);
        addr4.sin_family = AF_INET;
        addr4.sin_port = htons(CHAT_SERVER_PORT);
        addr4.sin_addr.s_addr = htonl(INADDR_ANY);
        NSData *address4 = [NSData dataWithBytes:&addr4 length:sizeof(addr4)];
        if (kCFSocketSuccess != CFSocketSetAddress(_socket, (CFDataRef)address4)) {
//            if (error) *error = [[NSError alloc]
//                                 initWithDomain:ServerErrorDomain
//                                 code:kServerCouldNotBindToIPv4Address
//                                 userInfo:nil];
            if (_socket) CFRelease(_socket);
            _socket = NULL;
            successful = NO;
        } else {
            // now that the binding was successful, we get the port number
            NSData *addr = (NSData *)CFBridgingRelease(CFSocketCopyAddress(_socket)) ;
            memcpy(&addr4, [addr bytes], [addr length]);
            self.port = ntohs(addr4.sin_port);
            // 将socket 输入源加入到当前的runloop
            CFRunLoopRef cfrl = CFRunLoopGetCurrent();
            CFRunLoopSourceRef source4 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
            CFRunLoopAddSource(cfrl, source4, kCFRunLoopDefaultMode);
            CFRelease(source4);
            //标准输入，当在命令行中输入时，回调函数便会被调用
            CFFileDescriptorContext context = {0,(__bridge void *)(self),NULL,NULL,NULL};
            CFFileDescriptorRef stdinFDRef = CFFileDescriptorCreate(kCFAllocatorDefault, STDIN_FILENO, true, FileDescriptorCallBack, &context);
            CFFileDescriptorEnableCallBacks(stdinFDRef,kCFFileDescriptorReadCallBack);
            CFRunLoopSourceRef stdinSource = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, stdinFDRef, 0);
            CFRunLoopAddSource(cfrl, stdinSource, kCFRunLoopDefaultMode);
            CFRelease(stdinSource);
            CFRelease(stdinFDRef);
            CFRunLoopRun();
        }
    }
    
    return successful;
}

- (void) stream:(NSStream*)stream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            break;
        }
        case NSStreamEventHasBytesAvailable: {
//            Client *client = [self.clients objectForKey:[NSString stringWithFormat:@"%d",stream]];
            NSMutableData *data = [NSMutableData data];
            uint8_t *buf = calloc(128, sizeof(uint8_t));
            NSUInteger len = 0;
            while([(NSInputStream*)stream hasBytesAvailable]) {
                len = [(NSInputStream*)stream read:buf maxLength:128];
                if(len > 0) {
                    [data appendBytes:buf length:len];
                }
            }
            free(buf);
            if ([data length] == 0) {
                //客户端退出
//                NSLog(@"客户端(sock_fd=%d)退出",client.sock_fd);
//                [self.clients removeObjectForKey:[NSString stringWithFormat:@"%d",stream]];
//                close(client.sock_fd);
            }else{
//                NSLog(@"收到客户端(sock_fd=%d)消息:%@",client.sock_fd,[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
            }
            break;
        }
        case NSStreamEventHasSpaceAvailable: {
            break;
        }
        case NSStreamEventEndEncountered: {
            break;
        }
        case NSStreamEventErrorOccurred: {
            break;
        }
        default:
            break;
    }
}
@end
