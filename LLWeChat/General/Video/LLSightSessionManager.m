//
//  LLSightSessionManager.m
//  LLWeChat
//
//  Created by GYJZH on 13/10/2016.
//  Copyright © 2016 GYJZH. All rights reserved.
//

#import "LLSightSessionManager.h"
#import "LLMovieRecorder.h"
#import "LLMovieRenderer.h"
#import "LLUtils.h"
@import AssetsLibrary;

#define RETAINED_BUFFER_COUNT 5

typedef NS_ENUM( NSInteger, VideoSnakeRecordingStatus ) {
    VideoSnakeRecordingStatusIdle = 0,
    VideoSnakeRecordingStatusStartingRecording,
    VideoSnakeRecordingStatusRecording,
    VideoSnakeRecordingStatusStoppingRecording,
};

@interface LLSightSessionManager () <AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, LLMovieRecorderDelegate>
{
    id <LLSightSessionManagerDelegate> _delegate;
    dispatch_queue_t _delegateCallbackQueue;
    
    NSMutableArray *_previousSecondTimestamps;
    
    AVCaptureSession *_captureSession;
    AVCaptureDevice *_videoDevice;
    AVCaptureConnection *_audioConnection;
    AVCaptureConnection *_videoConnection;
    BOOL _running;
    BOOL _startCaptureSessionOnEnteringForeground;
    id _applicationWillEnterForegroundNotificationObserver;
    
    dispatch_queue_t _sessionQueue;
    dispatch_queue_t _videoDataOutputQueue;
    dispatch_queue_t _motionSyncedVideoQueue;
    
    NSURL *_recordingURL;
    VideoSnakeRecordingStatus _recordingStatus;
    
    UIBackgroundTaskIdentifier _pipelineRunningTask;
    
    LLMovieRenderer *_renderer;
}

@property (readwrite) float videoFrameRate;
@property (readwrite) CMVideoDimensions videoDimensions;
@property (nonatomic, readwrite) AVCaptureVideoOrientation videoOrientation;


@property (nonatomic, retain) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;
@property (nonatomic, retain) __attribute__((NSObject)) CMFormatDescriptionRef outputAudioFormatDescription;
@property (nonatomic, retain) LLMovieRecorder *recorder;

@end



@implementation LLSightSessionManager

CREATE_SHARED_MANAGER(LLSightSessionManager)

- (id)init
{
    if (self = [super init]) {
        _previousSecondTimestamps = [[NSMutableArray alloc] init];
        _recordingOrientation = (AVCaptureVideoOrientation)UIDeviceOrientationPortrait;
        
        _recordingURL = [[NSURL alloc] initFileURLWithPath:[NSString pathWithComponents:@[NSTemporaryDirectory(), @"Movie.MP4"]]];
        
        _sessionQueue = dispatch_queue_create( "com.apple.sample.sessionmanager.capture", DISPATCH_QUEUE_SERIAL );
        
        // In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
        // In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
        // Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
        // AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
        _videoDataOutputQueue = dispatch_queue_create( "com.apple.sample.sessionmanager.video", DISPATCH_QUEUE_SERIAL );
        dispatch_set_target_queue( _videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0) );
        
        _renderer = [[LLMovieRenderer alloc] init];
        _pipelineRunningTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (void)dealloc {
    [self teardownCaptureSession];
}


#pragma mark Delegate

- (void)setDelegate:(id<LLSightSessionManagerDelegate>)delegate callbackQueue:(dispatch_queue_t)delegateCallbackQueue // delegate is weak referenced
{
    if ( delegate && ( delegateCallbackQueue == NULL ) )
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Caller must provide a delegateCallbackQueue" userInfo:nil];
    
    @synchronized( self ) {
        _delegate = delegate;
        _delegateCallbackQueue = delegateCallbackQueue;
    }
}


#pragma mark Capture Session

- (void)startRunning
{
    dispatch_sync( _sessionQueue, ^{
        [self setupCaptureSession];
        
        [_captureSession startRunning];
        _running = YES;
    });
}

- (void)stopRunning
{
    dispatch_sync( _sessionQueue, ^{
        _running = NO;
        
        // the captureSessionDidStopRunning method will stop recording if necessary as well, but we do it here so that the last video and audio samples are better aligned
        [self stopRecording]; // does nothing if we aren't currently recording
        
        [_captureSession stopRunning];
        
        [self captureSessionDidStopRunning];
        
        [self teardownCaptureSession];
    });
}

- (void)setupCaptureSession
{
    if ( _captureSession )
        return;
    
    _captureSession = [[AVCaptureSession alloc] init];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionNotification:) name:nil object:_captureSession];
    _applicationWillEnterForegroundNotificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:[UIApplication sharedApplication] queue:nil usingBlock:^(NSNotification *note) {
        // Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
        // Client must stop us running before we can be deallocated
        [self applicationWillEnterForeground];
    }];
    
#if RECORD_AUDIO
    /* Audio */
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:nil];
    if ([_captureSession canAddInput:audioIn])
        [_captureSession addInput:audioIn];
    [audioIn release];
    
    AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
    // Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
    dispatch_queue_t audioCaptureQueue = dispatch_queue_create("com.apple.sample.sessionmanager.audio", DISPATCH_QUEUE_SERIAL);
    [audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
    [audioCaptureQueue release];
    
    if ([_captureSession canAddOutput:audioOut])
        [_captureSession addOutput:audioOut];
    _audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
    [audioOut release];
#endif // RECORD_AUDIO
    
    /* Video */
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    _videoDevice = videoDevice;
    AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:nil];
    if ([_captureSession canAddInput:videoIn])
        [_captureSession addInput:videoIn];
    
    AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
    [videoOut setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    [videoOut setSampleBufferDelegate:self queue:_videoDataOutputQueue];
    
    // VideoSnake records videos and we prefer not to have any dropped frames in the video recording.
    // By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
    // We do however need to ensure that on average we can process frames in realtime.
    // If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
    [videoOut setAlwaysDiscardsLateVideoFrames:NO];
    
    if ([_captureSession canAddOutput:videoOut])
        [_captureSession addOutput:videoOut];
    _videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
    
    int frameRate;
    CMTime frameDuration = kCMTimeInvalid;
    // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
    if ( [[NSProcessInfo processInfo] processorCount] == 1 ) {
        if ( [_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480] )
            _captureSession.sessionPreset = AVCaptureSessionPreset640x480;
        frameRate = 15;
    }
    else {
        _captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        frameRate = 30;
    }
    frameDuration = CMTimeMake( 1, frameRate );
    
    NSError *error;
    if ([videoDevice lockForConfiguration:&error]) {
        [videoDevice setActiveVideoMaxFrameDuration:frameDuration];
        [videoDevice setActiveVideoMinFrameDuration:frameDuration];
        [videoDevice unlockForConfiguration];
    } else {
        NSLog(@"videoDevice lockForConfiguration returned error %@", error);
    }
    
    self.videoOrientation = [_videoConnection videoOrientation];
    
    return;
}

- (void)teardownCaptureSession
{
    if ( _captureSession ) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_captureSession];
        
        [[NSNotificationCenter defaultCenter] removeObserver:_applicationWillEnterForegroundNotificationObserver];
        _applicationWillEnterForegroundNotificationObserver = nil;
    
    }
}

- (void)captureSessionNotification:(NSNotification *)notification
{
    dispatch_async( _sessionQueue, ^{
        if ( [[notification name] isEqualToString:AVCaptureSessionWasInterruptedNotification] ) {
            NSLog( @"session interrupted" );
            
            [self captureSessionDidStopRunning];
        }
        else if ( [[notification name] isEqualToString:AVCaptureSessionInterruptionEndedNotification] ) {
            NSLog( @"session interruption ended" );
        }
        else if ( [[notification name] isEqualToString:AVCaptureSessionRuntimeErrorNotification] ) {
            [self captureSessionDidStopRunning];
            
            NSError *error = [[notification userInfo] objectForKey:AVCaptureSessionErrorKey];
            if ( error.code == AVErrorDeviceIsNotAvailableInBackground ) {
                NSLog( @"device not available in background" );
                
                // Since we can't resume running while in the background we need to remember this for next time we come to the foreground
                if ( _running )
                    _startCaptureSessionOnEnteringForeground = YES;
            }
            else if ( error.code == AVErrorMediaServicesWereReset ) {
                NSLog( @"media services were reset" );
                [self handleRecoverableCaptureSessionRuntimeError:error];
            }
            else {
                [self handleNonRecoverableCaptureSessionRuntimeError:error];
            }
        }
        else if ( [[notification name] isEqualToString:AVCaptureSessionDidStartRunningNotification] ) {
            NSLog( @"session started running" );
        }
        else if ( [[notification name] isEqualToString:AVCaptureSessionDidStopRunningNotification] ) {
            NSLog( @"session stopped running" );
        }
    });
}

- (void)handleRecoverableCaptureSessionRuntimeError:(NSError *)error
{
    if ( _running ) {
        [_captureSession startRunning];
    }
}

- (void)handleNonRecoverableCaptureSessionRuntimeError:(NSError *)error
{
    NSLog( @"fatal runtime error %@, code %i", error, (int)error.code );
    
    _running = NO;
    [self teardownCaptureSession];
    
    @synchronized( self ) {
        if ( _delegate ) {
            dispatch_async( _delegateCallbackQueue, ^{
                @autoreleasepool {
                    [_delegate sessionManager:self didStopRunningWithError:error];
                }
            });
        }
    }
}

- (void)captureSessionDidStopRunning
{
    [self stopRecording]; // does nothing if we aren't currently recording
    [self teardownVideoPipeline];
}

- (void)applicationWillEnterForeground
{
    NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
    
    dispatch_sync( _sessionQueue, ^{
        if ( _startCaptureSessionOnEnteringForeground ) {
            NSLog( @"-[%@ %@] manually restarting session", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
            
            _startCaptureSessionOnEnteringForeground = NO;
            if ( _running )
                [_captureSession startRunning];
        }
    });
}

#pragma mark Capture Pipeline

- (void)setupVideoPipelineWithInputFormatDescription:(CMFormatDescriptionRef)inputFormatDescription
{
    NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
    
    [self videoPipelineWillStartRunning];
    
 //   [self.motionSynchronizer setSampleBufferClock:_captureSession.masterClock];
    
//    [self.motionSynchronizer start];
    
    self.videoDimensions = CMVideoFormatDescriptionGetDimensions( inputFormatDescription );
    
    [_renderer prepareWithOutputDimensions:self.videoDimensions retainedBufferCountHint:RETAINED_BUFFER_COUNT];
    self.outputVideoFormatDescription = _renderer.outputFormatDescription;
}

// synchronous, blocks until the pipeline is drained, don't call from within the pipeline
- (void)teardownVideoPipeline
{
    // The session is stopped so we are guaranteed that no new buffers are coming through the video data output.
    // There may be inflight buffers on _videoDataOutputQueue or _motionSyncedVideoQueue however.
    // Synchronize with those queues to guarantee no more buffers are in flight.
    // Once the pipeline is drained we can tear it down safely.
    
    NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
    
    dispatch_sync( _videoDataOutputQueue, ^{
        
        if ( ! self.outputVideoFormatDescription )
            return;
        
 //       [self.motionSynchronizer stop]; // no new sbufs will be enqueued to _motionSyncedVideoQueue, but some may already be queued
//        dispatch_sync( _motionSyncedVideoQueue, ^{
//            self.outputVideoFormatDescription = nil;
//            [_renderer reset];
//            self.currentPreviewPixelBuffer = NULL;
//            
//            NSLog( @"-[%@ %@] finished teardown", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
//            
//            [self videoPipelineDidFinishRunning];
//        });
    });
}

- (void)videoPipelineWillStartRunning
{
    NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
    
    NSAssert( _pipelineRunningTask == UIBackgroundTaskInvalid, @"should not have a background task active before the video pipeline starts running" );
    
    _pipelineRunningTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        NSLog( @"video capture pipeline background task expired" );
    }];
}

- (void)videoPipelineDidFinishRunning
{
    NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
    
    NSAssert( _pipelineRunningTask != UIBackgroundTaskInvalid, @"should have a background task active when the video pipeline finishes running" );
    
    [[UIApplication sharedApplication] endBackgroundTask:_pipelineRunningTask];
    _pipelineRunningTask = UIBackgroundTaskInvalid;
}

// call under @synchronized( self )
- (void)videoPipelineDidRunOutOfBuffers
{
    // We have run out of buffers.
    // Tell the delegate so that it can flush any cached buffers.
    if ( _delegate ) {
        dispatch_async( _delegateCallbackQueue, ^{
            @autoreleasepool {
//                [_delegate sessionManagerDidRunOutOfPreviewBuffers:self];
            }
        });
    }
}


#pragma mark Pipeline Stage Output Callbacks

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // For video the basic sample flow is:
    //	1) Frame received from video data output on _videoDataOutputQueue via captureOutput:didOutputSampleBuffer:fromConnection: (this method)
    //	2) Frame sent to motion synchronizer to be asynchronously correlated with motion data
    //	3) Frame and correlated motion data received on _motionSyncedVideoQueue via motionSynchronizer:didOutputSampleBuffer:withMotion:
    //	4) Frame and motion data rendered via VideoSnakeOpenGLRenderer while running on _motionSyncedVideoQueue
    //	5) Rendered frame sent to the delegate for previewing
    //	6) Rendered frame sent to the movie recorder if recording is enabled
    
    // For audio the basic sample flow is:
    //	1) Audio sample buffer received from audio data output on an audio specific serial queue via captureOutput:didOutputSampleBuffer:fromConnection: (this method)
    //	2) Audio sample buffer sent to the movie recorder if recording is enabled
    
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    
    if ( connection == _videoConnection ) {
        if ( self.outputVideoFormatDescription == nil ) {
            [self setupVideoPipelineWithInputFormatDescription:formatDescription];
        }
        
    }
    else if ( connection == _audioConnection ) {
        self.outputAudioFormatDescription = formatDescription;
        
        @synchronized( self ) {
            if ( _recordingStatus == VideoSnakeRecordingStatusRecording ) {
                [self.recorder appendAudioSampleBuffer:sampleBuffer];
            }
        }
    }
}


#pragma mark Recording

- (void)startRecording
{
    @synchronized( self ) {
        if ( _recordingStatus != VideoSnakeRecordingStatusIdle ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already recording" userInfo:nil];
            return;
        }
        
        [self transitionToRecordingStatus:VideoSnakeRecordingStatusStartingRecording error:nil];
    }
    
    LLMovieRecorder *recorder = [[LLMovieRecorder alloc] initWithURL:_recordingURL];
    
#if RECORD_AUDIO
    [recorder addAudioTrackWithSourceFormatDescription:self.outputAudioFormatDescription];
#endif // RECORD_AUDIO
    
    CGAffineTransform videoTransform = [self transformFromVideoBufferOrientationToOrientation:self.recordingOrientation withAutoMirroring:NO]; // Front camera recording shouldn't be mirrored
    
    [recorder addVideoTrackWithSourceFormatDescription:self.outputVideoFormatDescription transform:videoTransform];
    
    dispatch_queue_t callbackQueue = dispatch_queue_create( "com.apple.sample.sessionmanager.recordercallback", DISPATCH_QUEUE_SERIAL ); // guarantee ordering of callbacks with a serial queue
    [recorder setDelegate:self callbackQueue:callbackQueue];
    self.recorder = recorder;
    
    [recorder prepareToRecord]; // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
}

- (void)stopRecording
{
    @synchronized( self ) {
        if ( _recordingStatus != VideoSnakeRecordingStatusRecording ) {
            return;
        }
        
        [self transitionToRecordingStatus:VideoSnakeRecordingStatusStoppingRecording error:nil];
    }
    
    [self.recorder finishRecording]; // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
}

#pragma mark MovieRecorder Delegate

- (void)movieRecorderDidFinishPreparing:(LLMovieRecorder *)recorder
{
    @synchronized( self ) {
        if ( _recordingStatus != VideoSnakeRecordingStatusStartingRecording ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StartingRecording state" userInfo:nil];
            return;
        }
        
        [self transitionToRecordingStatus:VideoSnakeRecordingStatusRecording error:nil];
    }
}

- (void)movieRecorder:(LLMovieRecorder *)recorder didFailWithError:(NSError *)error
{
    @synchronized( self ) {
        self.recorder = nil;
        [self transitionToRecordingStatus:VideoSnakeRecordingStatusIdle error:error];
    }
}

- (void)movieRecorderDidFinishRecording:(LLMovieRecorder *)recorder
{
    @synchronized( self ) {
        if ( _recordingStatus != VideoSnakeRecordingStatusStoppingRecording ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
            return;
        }
        
        // No state transition, we are still in the process of stopping.
        // We will be stopped once we save to the assets library.
    }
    
    self.recorder = nil;
    
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    [library writeVideoAtPathToSavedPhotosAlbum:_recordingURL completionBlock:^(NSURL *assetURL, NSError *error) {
        
        [[NSFileManager defaultManager] removeItemAtURL:_recordingURL error:NULL];
        
        @synchronized( self ) {
            if ( _recordingStatus != VideoSnakeRecordingStatusStoppingRecording ) {
                @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
                return;
            }
            [self transitionToRecordingStatus:VideoSnakeRecordingStatusIdle error:error];
        }
    }];
}

#pragma mark Recording State Machine

// call under @synchonized( self )
- (void)transitionToRecordingStatus:(VideoSnakeRecordingStatus)newStatus error:(NSError*)error
{
    SEL delegateSelector = NULL;
    VideoSnakeRecordingStatus oldStatus = _recordingStatus;
    _recordingStatus = newStatus;
    
#if LOG_STATUS_TRANSITIONS
    NSLog( @"VideoSnakeSessionManager recording state transition: %@->%@", [self stringForRecordingStatus:oldStatus], [self stringForRecordingStatus:newStatus] );
#endif
    
    if ( newStatus != oldStatus ) {
        if ( error && ( newStatus == VideoSnakeRecordingStatusIdle ) ) {
            delegateSelector = @selector(sessionManager:recordingDidFailWithError:);
        }
        else {
            error = nil; // only the above delegate method takes an error
            if ( ( oldStatus == VideoSnakeRecordingStatusStartingRecording ) && ( newStatus == VideoSnakeRecordingStatusRecording ) )
                delegateSelector = @selector(sessionManagerRecordingDidStart:);
            else if ( ( oldStatus == VideoSnakeRecordingStatusRecording ) && ( newStatus == VideoSnakeRecordingStatusStoppingRecording ) )
                delegateSelector = @selector(sessionManagerRecordingWillStop:);
            else if ( ( oldStatus == VideoSnakeRecordingStatusStoppingRecording ) && ( newStatus == VideoSnakeRecordingStatusIdle ) )
                delegateSelector = @selector(sessionManagerRecordingDidStop:);
        }
    }
    
    if ( delegateSelector && _delegate ) {
        dispatch_async( _delegateCallbackQueue, ^{
            @autoreleasepool {
                if ( error )
                    [_delegate performSelector:delegateSelector withObject:self withObject:error];
                else
                    [_delegate performSelector:delegateSelector withObject:self];
            }
        });
    }
}

#if LOG_STATUS_TRANSITIONS

- (NSString*)stringForRecordingStatus:(VideoSnakeRecordingStatus)status
{
    NSString *statusString = nil;
    
    switch ( status ) {
        case VideoSnakeRecordingStatusIdle:
            statusString = @"Idle";
            break;
        case VideoSnakeRecordingStatusStartingRecording:
            statusString = @"StartingRecording";
            break;
        case VideoSnakeRecordingStatusRecording:
            statusString = @"Recording";
            break;
        case VideoSnakeRecordingStatusStoppingRecording:
            statusString = @"StoppingRecording";
            break;
        default:
            statusString = @"Unknown";
            break;
    }
    return statusString;
}

#endif // LOG_STATUS_TRANSITIONS

#pragma mark Utilities

// Auto mirroring: Front camera is mirrored; back camera isn't 
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror
{
    CGAffineTransform transform = CGAffineTransformIdentity;
    
//    // Calculate offsets from an arbitrary reference orientation (portrait)
//    CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( orientation );
//    CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( self.videoOrientation );
//    
//    // Find the difference in angle between the desired orientation and the video orientation
//    CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
//    transform = CGAffineTransformMakeRotation(angleOffset);
//    
//    if ( _videoDevice.position == AVCaptureDevicePositionFront ) {
//        if ( mirror ) {
//            transform = CGAffineTransformScale(transform, -1, 1);
//        }
//        else {
//            if ( UIInterfaceOrientationIsPortrait((UIInterfaceOrientation)orientation) ) {
//                transform = CGAffineTransformRotate(transform, M_PI);
//            }
//        }
//    }
    
    return transform;
}

- (void)calculateFramerateAtTimestamp:(CMTime)timestamp
{
    [_previousSecondTimestamps addObject:[NSValue valueWithCMTime:timestamp]];
    
    CMTime oneSecond = CMTimeMake( 1, 1 );
    CMTime oneSecondAgo = CMTimeSubtract( timestamp, oneSecond );
    
    while( CMTIME_COMPARE_INLINE( [[_previousSecondTimestamps objectAtIndex:0] CMTimeValue], <, oneSecondAgo ) )
        [_previousSecondTimestamps removeObjectAtIndex:0];
    
    if ( [_previousSecondTimestamps count] > 1 ) {
        const Float64 duration = CMTimeGetSeconds(CMTimeSubtract([[_previousSecondTimestamps lastObject] CMTimeValue], [[_previousSecondTimestamps objectAtIndex:0] CMTimeValue]));
        const float newRate = (float) ([_previousSecondTimestamps count] - 1) / duration;
        self.videoFrameRate = newRate;
    }
}





@end
