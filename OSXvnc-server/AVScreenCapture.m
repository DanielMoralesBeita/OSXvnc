//
//  AVScreenCapture.m
//  OSXvnc
//
//  Created by Mykola Mokhnach on Mon Jan 14 2019.
//  Copyright (c) 2019 Sauce Labs Inc. All rights reserved.
//

#import "AVScreenCapture.h"

#import "AVSampleBufferHolder.h"

@interface AVScreenCapture() <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, retain) AVSampleBufferHolder *sampleBufferHolder;
@property (nonatomic) CGDisplayStreamRef displayStream;
@property (nonatomic, readonly) CGScreenRefreshCallback refreshCallback;
@property (nonatomic, readonly, copy) NSMutableArray *fifo;
@property (nonatomic, readonly) CFDictionaryRef pixelBufferAttributes;

@end

@implementation AVScreenCapture

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID refreshCallback:(CGScreenRefreshCallback)refreshCallback
{
    if ((self = [super init])) {
        _displayID = displayID;
        _displayStream = nil;
        _refreshCallback = refreshCallback;
        _fifo = [[NSMutableArray alloc] init];
        _sampleBufferHolder = [[AVSampleBufferHolder alloc] init];

        int pixelFormat = kCVPixelFormatType_32BGRA;
        CFNumberRef number = CFNumberCreate(
                                            ( CFAllocatorRef )NULL,
                                            kCFNumberSInt32Type,
                                            &pixelFormat
                                            );
        CFTypeRef values[1];
        values[0] = number;
        _pixelBufferAttributes = CFDictionaryCreate(kCFAllocatorDefault,
                                                    (const void* []){kCVPixelBufferPixelFormatTypeKey},
                                                    (const void**) values,
                                                    1,
                                                    &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
        CFRelease(number);
    }
    return self;
}

- (void)dealloc {
    [self stop];

    [_sampleBufferHolder release];
    _sampleBufferHolder = nil;

    CFRelease(_pixelBufferAttributes);

    [super dealloc];
}

- (BOOL)startWithWidth:(size_t)width height:(size_t)height
{
    if (nil != self.displayStream) {
        return YES;
    }

    CGDisplayStreamFrameAvailableHandler handler = ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
                                                     IOSurfaceRef __nullable frameSurface,
                                                     CGDisplayStreamUpdateRef __nullable updateRef) {
        if (kCGDisplayStreamFrameStatusStopped == status) {
            CGDisplayStreamRef streamRef = nil;
            @synchronized (self.fifo) {
                if (self.fifo.count > 0) {
                    streamRef = (__bridge CGDisplayStreamRef)self.fifo.lastObject;
                    [self.fifo removeObjectAtIndex:self.fifo.count - 1];
                }
            }
            if (streamRef) {
                CFRelease(streamRef);
                streamRef = nil;
            }
        }
        // Only pay attention to frame updates.
        if (status != kCGDisplayStreamFrameStatusFrameComplete || !frameSurface || !updateRef) {
            return;
        }
        @synchronized (self.sampleBufferHolder) {
            self.sampleBufferHolder.sampleBuffer = frameSurface;
            self.sampleBufferHolder.timestamp = displayTime;
        }
        size_t count = 0;
        const CGRect* rects = CGDisplayStreamUpdateGetRects(updateRef, kCGDisplayStreamUpdateDirtyRects, &count);
        if (count > 0) {
            self.refreshCallback((uint32_t)count, rects, nil);
        }
    };

    CFDictionaryRef propertiesDict = CFDictionaryCreate(kCFAllocatorDefault,
                                                         (const void* []){kCGDisplayStreamShowCursor},
                                                         (const void* []){kCFBooleanFalse},
                                                         1,
                                                         &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    self.displayStream = CGDisplayStreamCreate(self.displayID, width, height, 'BGRA', propertiesDict, handler);
    CFRelease(propertiesDict);
    if (self.displayStream) {
        CGError error = CGDisplayStreamStart(self.displayStream);
        if (error != kCGErrorSuccess) {
            self.displayStream = nil;
            return NO;
        }
        CFRunLoopSourceRef source = CGDisplayStreamGetRunLoopSource(self.displayStream);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        return YES;
    }
    return NO;
}

- (void)stop
{
    if (nil == self.displayStream) {
        return;
    }

    CFRunLoopSourceRef source = CGDisplayStreamGetRunLoopSource(self.displayStream);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGDisplayStreamStop(self.displayStream);
    @synchronized (self.fifo) {
        [self.fifo insertObject:(__bridge id)self.displayStream atIndex:0];
    }
    self.displayStream = nil;
}

+ (char *)frameDataWithBuffer:(CVPixelBufferRef)screenBuffer dataLength:(size_t *)dataLength
{
    CVPixelBufferLockBaseAddress(screenBuffer, 0);
    char *baseAddress = CVPixelBufferGetBaseAddress(screenBuffer);
    const size_t screenWidth = CVPixelBufferGetWidth(screenBuffer);
    const size_t screenHeight = CVPixelBufferGetHeight(screenBuffer);
    const size_t pixelsLength = BYTES_PER_PIXEL * screenWidth * screenHeight;
    char *pixels = malloc(pixelsLength);
    memcpy(pixels, baseAddress, pixelsLength);
    CVPixelBufferUnlockBaseAddress(screenBuffer, 0);
    if (dataLength) {
        *dataLength = pixelsLength;
    }
    return pixels;
}

- (BOOL)retrieveLastFrame:(char **)frameData
               dataLength:(size_t *)dataLength
                timestamp:(uint64_t *)timestamp
{
    if (nil == self.displayStream || nil == frameData) {
        return NO;
    }

    IOSurfaceRef surface = nil;
    @synchronized (self.sampleBufferHolder) {
        surface = self.sampleBufferHolder.sampleBuffer;
        if (nil == surface) {
            return NO;
        }
        CFRetain(surface);
        IOSurfaceIncrementUseCount(surface);
        if (timestamp) {
            *timestamp = self.sampleBufferHolder.timestamp;
        }
    }
    CVPixelBufferRef screenBuffer = nil;
    CVReturn status = CVPixelBufferCreateWithIOSurface(NULL, surface, self.pixelBufferAttributes, &screenBuffer);
    if (status != kCVReturnSuccess || !screenBuffer) {
        IOSurfaceDecrementUseCount(surface);
        CFRelease(surface);
        return NO;
    }
    *frameData = [self.class frameDataWithBuffer:screenBuffer dataLength:dataLength];
    CVPixelBufferRelease(screenBuffer);
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
    return nil != *frameData;
}

@end
