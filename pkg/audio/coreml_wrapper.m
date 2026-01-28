#import "coreml_wrapper.h"
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

@interface CoreMLUpsamplerInternal : NSObject
@property(nonatomic, strong) MLModel *model;
@property(nonatomic, strong) NSString *inputName;
@property(nonatomic, strong) NSString *outputName;
@end

@implementation CoreMLUpsamplerInternal
@end

struct CoreMLUpsampler {
  CoreMLUpsamplerInternal *internal;
};

CoreMLUpsampler *coreml_upsampler_create(const char *model_path) {
  @autoreleasepool {
    NSString *path = [NSString stringWithUTF8String:model_path];
    NSURL *modelURL = [NSURL fileURLWithPath:path];

    NSError *error = nil;
    MLModelConfiguration *config = [[MLModelConfiguration alloc] init];

    // Prefer ANE (Apple Neural Engine)
    config.computeUnits = MLComputeUnitsAll;

    MLModel *model = [MLModel modelWithContentsOfURL:modelURL
                                       configuration:config
                                               error:&error];
    if (error || !model) {
      NSLog(@"[CoreML] Failed to load model: %@", error);
      return NULL;
    }

    CoreMLUpsampler *upsampler =
        (CoreMLUpsampler *)malloc(sizeof(CoreMLUpsampler));
    upsampler->internal = [[CoreMLUpsamplerInternal alloc] init];
    upsampler->internal.model = model;

    // Inspect model to find input/output names (simplified)
    upsampler->internal.inputName =
        model.modelDescription.inputDescriptionsByName.allKeys.firstObject;
    upsampler->internal.outputName =
        model.modelDescription.outputDescriptionsByName.allKeys.firstObject;

    return upsampler;
  }
}

bool coreml_upsampler_process(CoreMLUpsampler *upsampler, const float *input,
                              size_t input_size, float *output,
                              size_t *output_size) {
  if (!upsampler || !upsampler->internal)
    return false;

  @autoreleasepool {
    NSError *error = nil;

    // Create MLMultiArray from input samples
    // Note: Actual implementation depends on model input shape (e.g., [1, size]
    // or [size])
    NSArray *shape = @[ @(1), @(input_size) ];
    MLMultiArray *inputArray =
        [[MLMultiArray alloc] initWithDataPointer:(void *)input
                                            shape:shape
                                         dataType:MLMultiArrayDataTypeFloat32
                                          strides:@[ @(input_size), @(1) ]
                                      deallocator:nil
                                            error:&error];
    if (error)
      return false;

    NSDictionary *inputDict = @{upsampler->internal.inputName : inputArray};
    id<MLFeatureProvider> inputFeatures =
        [[MLDictionaryFeatureProvider alloc] initWithDictionary:inputDict
                                                          error:&error];

    id<MLFeatureProvider> outputFeatures =
        [upsampler->internal.model predictionFromFeatures:inputFeatures
                                                    error:&error];
    if (error) {
      NSLog(@"[CoreML] Prediction error: %@", error);
      return false;
    }

    MLFeatureValue *outputValue =
        [outputFeatures featureValueForName:upsampler->internal.outputName];
    MLMultiArray *outputArray = outputValue.multiArrayValue;

    // Copy data back
    float *outputPtr = (float *)outputArray.dataPointer;
    size_t count = outputArray.count;
    memcpy(output, outputPtr, count * sizeof(float));
    *output_size = count;

    return true;
  }
}

void coreml_upsampler_destroy(CoreMLUpsampler *upsampler) {
  if (upsampler) {
    if (upsampler->internal) {
      upsampler->internal = nil;
    }
    free(upsampler);
  }
}
