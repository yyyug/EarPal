#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SenseVoiceGGMLBridgeErrorDomain;

typedef NS_ERROR_ENUM(SenseVoiceGGMLBridgeErrorDomain, SenseVoiceGGMLBridgeErrorCode) {
    SenseVoiceGGMLBridgeErrorCodeModelMissing = 1,
    SenseVoiceGGMLBridgeErrorCodeInitializationFailed = 2,
    SenseVoiceGGMLBridgeErrorCodeInvalidLanguage = 3,
    SenseVoiceGGMLBridgeErrorCodeDecodeFailed = 4,
    SenseVoiceGGMLBridgeErrorCodeInvalidAudio = 5,
};

@interface SenseVoiceGGMLRecognizer : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                  language:(NSString *)language
                                    useITN:(BOOL)useITN
                                   threads:(NSInteger)threads
                                     error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NSString *)transcribePCMFloatData:(NSData *)pcmFloatData
                                  sampleCount:(NSInteger)sampleCount
                                        error:(NSError * _Nullable * _Nullable)error;

- (void)unload;

@end

NS_ASSUME_NONNULL_END
