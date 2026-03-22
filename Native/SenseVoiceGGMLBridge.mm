#import "SenseVoiceGGMLBridge.h"

#import <algorithm>
#import <string>
#import <vector>

#include "sense-voice.h"

NSErrorDomain const SenseVoiceGGMLBridgeErrorDomain = @"SenseVoiceGGMLBridgeErrorDomain";

namespace {

NSError *SenseVoiceGGMLMakeError(SenseVoiceGGMLBridgeErrorCode code, NSString *description) {
    return [NSError errorWithDomain:SenseVoiceGGMLBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

NSString *SenseVoiceGGMLTranscriptFromContext(struct sense_voice_context *context) {
    if (context == nullptr || context->state == nullptr) {
        return @"";
    }

    NSMutableString *result = [NSMutableString string];
    const auto &ids = context->state->ids;
    int previousTokenID = -1;

    for (size_t index = 0; index < ids.size(); ++index) {
        const int tokenID = ids[index];
        if (tokenID == 0) {
            previousTokenID = tokenID;
            continue;
        }
        if (tokenID == previousTokenID) {
            continue;
        }
        previousTokenID = tokenID;

        const auto token = context->vocab.id_to_token.find(tokenID);
        if (token == context->vocab.id_to_token.end()) {
            continue;
        }

        NSString *piece = [NSString stringWithUTF8String:token->second.c_str()];
        if (piece != nil &&
            ![piece hasPrefix:@"<|"] &&
            !([piece hasPrefix:@"<"] && [piece hasSuffix:@">"])) {
            [result appendString:piece];
        }
    }

    NSString *normalized = [result stringByReplacingOccurrencesOfString:@"▁" withString:@" "];
    return [normalized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

void SenseVoiceGGMLFreeContext(struct sense_voice_context *context) {
    if (context == nullptr) {
        return;
    }

    ggml_free(context->model.ctx);
    ggml_backend_buffer_free(context->model.buffer);
    ggml_backend_buffer_free(context->vad_model.buffer);

    sense_voice_free_state(context->state);

    delete context->model.model->encoder;
    delete context->model.model;
    delete context->vad_model.model;
    delete context;
}

}  // namespace

@implementation SenseVoiceGGMLRecognizer {
    struct sense_voice_context *_context;
    struct sense_voice_full_params _params;
    std::string _languageCode;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                  language:(NSString *)language
                                    useITN:(BOOL)useITN
                                   threads:(NSInteger)threads
                                     error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        if (error != nullptr) {
            *error = SenseVoiceGGMLMakeError(
                SenseVoiceGGMLBridgeErrorCodeModelMissing,
                @"The SenseVoice GGUF model file is missing."
            );
        }
        return nil;
    }

    NSString *resolvedLanguage = language.length > 0 ? language : @"auto";
    _languageCode = std::string(resolvedLanguage.UTF8String ?: "auto");

    const int languageID = sense_voice_lang_id(_languageCode.c_str());
    if (languageID < 0) {
        if (error != nullptr) {
            *error = SenseVoiceGGMLMakeError(
                SenseVoiceGGMLBridgeErrorCodeInvalidLanguage,
                [NSString stringWithFormat:@"Unsupported SenseVoice language code: %@", resolvedLanguage]
            );
        }
        return nil;
    }

    auto makeContextParams = ^(bool useGPU) {
        struct sense_voice_context_params params = sense_voice_context_default_params();
        params.use_gpu = useGPU;
        params.use_itn = useITN;
        params.flash_attn = false;
        params.gpu_device = 0;
        params.cb_eval = nullptr;
        params.cb_eval_user_data = nullptr;
        return params;
    };

    struct sense_voice_context_params contextParams = makeContextParams(true);
    _context = sense_voice_small_init_from_file_with_params(modelPath.fileSystemRepresentation, contextParams);
    if (_context == nullptr) {
        contextParams = makeContextParams(false);
        _context = sense_voice_small_init_from_file_with_params(modelPath.fileSystemRepresentation, contextParams);
    }
    if (_context == nullptr) {
        if (error != nullptr) {
            *error = SenseVoiceGGMLMakeError(
                SenseVoiceGGMLBridgeErrorCodeInitializationFailed,
                @"SenseVoice ggml failed to initialize with Metal or CPU."
            );
        }
        return nil;
    }

    _context->language_id = languageID;

    _params = sense_voice_full_default_params(SENSE_VOICE_SAMPLING_GREEDY);
    _params.n_threads = std::max(1, static_cast<int>(threads));
    _params.language = _languageCode.c_str();
    _params.no_timestamps = true;
    _params.single_segment = true;
    _params.print_progress = false;
    _params.print_timestamps = false;
    _params.debug_mode = false;
    _params.audio_ctx = 0;
    _params.progress_callback = nullptr;
    _params.progress_callback_user_data = nullptr;

    return self;
}

- (void)dealloc {
    [self unload];
}

- (nullable NSString *)transcribePCMFloatData:(NSData *)pcmFloatData
                                  sampleCount:(NSInteger)sampleCount
                                        error:(NSError * _Nullable * _Nullable)error {
    if (_context == nullptr) {
        if (error != nullptr) {
            *error = SenseVoiceGGMLMakeError(
                SenseVoiceGGMLBridgeErrorCodeInitializationFailed,
                @"SenseVoice ggml is not initialized."
            );
        }
        return nil;
    }

    if (sampleCount <= 0 || pcmFloatData.length < static_cast<NSUInteger>(sampleCount) * sizeof(float)) {
        if (error != nullptr) {
            *error = SenseVoiceGGMLMakeError(
                SenseVoiceGGMLBridgeErrorCodeInvalidAudio,
                @"The audio buffer is empty or incomplete."
            );
        }
        return nil;
    }

    const float *samples = static_cast<const float *>(pcmFloatData.bytes);
    std::vector<double> pcm;
    pcm.reserve(static_cast<size_t>(sampleCount));
    for (NSInteger index = 0; index < sampleCount; ++index) {
        pcm.push_back(static_cast<double>(samples[index]));
    }

    if (sense_voice_full_parallel(_context, _params, pcm, static_cast<int>(sampleCount), 1) != 0) {
        if (error != nullptr) {
            *error = SenseVoiceGGMLMakeError(
                SenseVoiceGGMLBridgeErrorCodeDecodeFailed,
                @"SenseVoice ggml failed to decode the current audio chunk."
            );
        }
        return nil;
    }

    return SenseVoiceGGMLTranscriptFromContext(_context);
}

- (void)unload {
    if (_context != nullptr) {
        SenseVoiceGGMLFreeContext(_context);
        _context = nullptr;
    }
}

@end
