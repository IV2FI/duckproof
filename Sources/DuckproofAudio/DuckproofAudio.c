#include "DuckproofAudio.h"

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// Stereo ring buffer with a single writer (input IOProc) and a single reader
// (output render callback): atomic indices are enough, no locks on real-time threads.
#define kRingFrames     16384u            // power of two, ~340 ms at 48 kHz
#define kRingMask       (kRingFrames - 1u)
#define kChannels       2u
#define kInputSlack     1024u             // headroom for the input block size
#define kMaxExtraFrames 4800u             // beyond this (~100 ms of extra delay) we catch up

struct UDPassthrough {
    float ring[kRingFrames * kChannels];
    _Atomic uint64_t writePos;
    _Atomic uint64_t readPos;
    _Atomic uint64_t underruns;
    _Atomic uint32_t peakBits;
    _Atomic uint32_t gainBits;            // float, set from the main thread
    bool priming;                         // touched by the reader only

    AudioObjectID inputDevice;
    AudioDeviceIOProcID ioProcID;
    AudioUnit outputUnit;
};

static void store_peak(UDPassthrough *pt, float peak) {
    uint32_t bits;
    memcpy(&bits, &peak, sizeof bits);
    uint32_t current = atomic_load_explicit(&pt->peakBits, memory_order_relaxed);
    float currentValue;
    memcpy(&currentValue, &current, sizeof currentValue);
    while (peak > currentValue &&
           !atomic_compare_exchange_weak_explicit(&pt->peakBits, &current, bits,
                                                  memory_order_relaxed, memory_order_relaxed)) {
        memcpy(&currentValue, &current, sizeof currentValue);
    }
}

static float load_float(_Atomic uint32_t *bits) {
    const uint32_t raw = atomic_load_explicit(bits, memory_order_relaxed);
    float value;
    memcpy(&value, &raw, sizeof value);
    return value;
}

/// Gain followed by a soft limiter: transparent below 0.8, then curves smoothly toward 1.0
/// instead of clipping, so a boosted loud voice doesn't crackle.
static inline float boost(float x, float gain) {
    const float y = x * gain;
    const float a = fabsf(y);
    if (a <= 0.8f) return y;
    return copysignf(0.8f + 0.2f * tanhf((a - 0.8f) / 0.2f), y);
}

static OSStatus input_proc(AudioObjectID device, const AudioTimeStamp *now,
                           const AudioBufferList *input, const AudioTimeStamp *inputTime,
                           AudioBufferList *output, const AudioTimeStamp *outputTime,
                           void *context) {
    UDPassthrough *pt = context;
    if (input == NULL || input->mNumberBuffers == 0 || input->mBuffers[0].mData == NULL) return noErr;

    const bool interleaved = input->mNumberBuffers == 1;
    const uint32_t inChannels = interleaved ? input->mBuffers[0].mNumberChannels : input->mNumberBuffers;
    if (inChannels == 0) return noErr;
    uint32_t frames = input->mBuffers[0].mDataByteSize / (uint32_t)(sizeof(float) * (interleaved ? inChannels : 1));

    const uint64_t w = atomic_load_explicit(&pt->writePos, memory_order_relaxed);
    const uint64_t r = atomic_load_explicit(&pt->readPos, memory_order_acquire);
    const uint64_t space = kRingFrames - (w - r);
    if (frames > space) frames = (uint32_t)space;   // reader stalled: drop the excess

    float peak = 0.f;
    for (uint32_t i = 0; i < frames; i++) {
        float *dst = &pt->ring[((w + i) & kRingMask) * kChannels];
        for (uint32_t c = 0; c < kChannels; c++) {
            const uint32_t src = c < inChannels ? c : inChannels - 1;   // mono → both ears
            const float v = interleaved ? ((const float *)input->mBuffers[0].mData)[i * inChannels + src]
                                        : ((const float *)input->mBuffers[src].mData)[i];
            dst[c] = v;
            const float a = fabsf(v);
            if (a > peak) peak = a;
        }
    }
    atomic_store_explicit(&pt->writePos, w + frames, memory_order_release);
    store_peak(pt, peak);
    return noErr;
}

static OSStatus render_proc(void *context, AudioUnitRenderActionFlags *flags,
                            const AudioTimeStamp *timeStamp, UInt32 bus, UInt32 frames,
                            AudioBufferList *io) {
    UDPassthrough *pt = context;
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);

    uint64_t r = atomic_load_explicit(&pt->readPos, memory_order_relaxed);
    const uint64_t w = atomic_load_explicit(&pt->writePos, memory_order_acquire);
    uint64_t available = w - r;
    const uint64_t prime = (uint64_t)frames + kInputSlack;

    if (pt->priming) {
        if (available < prime) return noErr;
        pt->priming = false;
    }
    if (available > prime + kMaxExtraFrames) {      // input clock runs faster than output
        r = w - prime;
        available = prime;
    }

    const uint32_t n = available < frames ? (uint32_t)available : frames;
    const float gain = load_float(&pt->gainBits);
    const bool interleaved = io->mNumberBuffers == 1;
    for (uint32_t i = 0; i < n; i++) {
        const float *src = &pt->ring[((r + i) & kRingMask) * kChannels];
        for (uint32_t c = 0; c < kChannels; c++) {
            if (interleaved) {
                const uint32_t outChannels = io->mBuffers[0].mNumberChannels;
                if (c < outChannels) ((float *)io->mBuffers[0].mData)[i * outChannels + c] = boost(src[c], gain);
            } else if (c < io->mNumberBuffers) {
                ((float *)io->mBuffers[c].mData)[i] = boost(src[c], gain);
            }
        }
    }
    atomic_store_explicit(&pt->readPos, r + n, memory_order_release);

    if (n < frames) {                                // output runs faster: re-prime
        pt->priming = true;
        atomic_fetch_add_explicit(&pt->underruns, 1, memory_order_relaxed);
    }
    return noErr;
}

UDPassthrough *ud_passthrough_create(void) {
    UDPassthrough *pt = calloc(1, sizeof(UDPassthrough));
    if (pt != NULL) ud_passthrough_set_gain(pt, 1.0f);
    return pt;
}

void ud_passthrough_set_gain(UDPassthrough *pt, float gain) {
    uint32_t bits;
    memcpy(&bits, &gain, sizeof bits);
    atomic_store_explicit(&pt->gainBits, bits, memory_order_relaxed);
}

void ud_passthrough_destroy(UDPassthrough *pt) {
    if (pt == NULL) return;
    ud_passthrough_stop(pt);
    free(pt);
}

void ud_passthrough_stop(UDPassthrough *pt) {
    if (pt->outputUnit != NULL) {
        AudioOutputUnitStop(pt->outputUnit);
        AudioUnitUninitialize(pt->outputUnit);
        AudioComponentInstanceDispose(pt->outputUnit);
        pt->outputUnit = NULL;
    }
    if (pt->ioProcID != NULL) {
        AudioDeviceStop(pt->inputDevice, pt->ioProcID);
        AudioDeviceDestroyIOProcID(pt->inputDevice, pt->ioProcID);
        pt->ioProcID = NULL;
    }
}

OSStatus ud_passthrough_start(UDPassthrough *pt, AudioObjectID inputDevice, AudioObjectID outputDevice) {
    ud_passthrough_stop(pt);
    atomic_store(&pt->writePos, 0);
    atomic_store(&pt->readPos, 0);
    pt->priming = true;
    pt->inputDevice = inputDevice;

    Float64 sampleRate = 48000.0;
    UInt32 size = sizeof sampleRate;
    AudioObjectPropertyAddress rateAddress = {
        kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    OSStatus err = AudioObjectGetPropertyData(inputDevice, &rateAddress, 0, NULL, &size, &sampleRate);
    if (err != noErr) return err;

    // Output: a HAL unit, which handles resampling to the AirPods' format.
    AudioComponentDescription desc = {
        kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    if (component == NULL) return kAudioHardwareUnspecifiedError;
    if ((err = AudioComponentInstanceNew(component, &pt->outputUnit)) != noErr) goto fail;

    if ((err = AudioUnitSetProperty(pt->outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &outputDevice, sizeof outputDevice)) != noErr) goto fail;

    AudioStreamBasicDescription format = {
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = sizeof(float) * kChannels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float) * kChannels,
        .mChannelsPerFrame = kChannels,
        .mBitsPerChannel = 32,
    };
    if ((err = AudioUnitSetProperty(pt->outputUnit, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0, &format, sizeof format)) != noErr) goto fail;

    AURenderCallbackStruct callback = { render_proc, pt };
    if ((err = AudioUnitSetProperty(pt->outputUnit, kAudioUnitProperty_SetRenderCallback,
                                    kAudioUnitScope_Input, 0, &callback, sizeof callback)) != noErr) goto fail;
    if ((err = AudioUnitInitialize(pt->outputUnit)) != noErr) goto fail;

    // Input: an IOProc directly on the Duckproof driver.
    if ((err = AudioDeviceCreateIOProcID(inputDevice, input_proc, pt, &pt->ioProcID)) != noErr) goto fail;
    if ((err = AudioDeviceStart(inputDevice, pt->ioProcID)) != noErr) goto fail;
    if ((err = AudioOutputUnitStart(pt->outputUnit)) != noErr) goto fail;
    return noErr;

fail:
    ud_passthrough_stop(pt);
    return err;
}

uint64_t ud_passthrough_underruns(const UDPassthrough *pt) {
    return atomic_load_explicit(&pt->underruns, memory_order_relaxed);
}

float ud_passthrough_take_peak(UDPassthrough *pt) {
    const uint32_t bits = atomic_exchange_explicit(&pt->peakBits, 0, memory_order_relaxed);
    float peak;
    memcpy(&peak, &bits, sizeof peak);
    return peak;
}
