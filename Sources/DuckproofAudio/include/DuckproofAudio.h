#ifndef DUCKPROOF_AUDIO_H
#define DUCKPROOF_AUDIO_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

/// Continuously copies a device's input (the Duckproof driver, where FaceTime plays)
/// to an output device (the AirPods) through a small ring buffer.
/// The two clocks aren't synchronized, so the buffer skips or pads with silence
/// when it drifts too far: inaudible in practice for speech.
typedef struct UDPassthrough UDPassthrough;

UDPassthrough *ud_passthrough_create(void);
void ud_passthrough_destroy(UDPassthrough *pt);

/// Starts forwarding. Returns noErr or the Core Audio error code.
OSStatus ud_passthrough_start(UDPassthrough *pt, AudioObjectID inputDevice, AudioObjectID outputDevice);
void ud_passthrough_stop(UDPassthrough *pt);

/// Volume applied to the forwarded audio (1 = unchanged), with a soft limiter above 1.
void ud_passthrough_set_gain(UDPassthrough *pt, float gain);

/// Number of times the output ran out of data (diagnostics).
uint64_t ud_passthrough_underruns(const UDPassthrough *pt);
/// Peak of the forwarded signal since the last call (0…1), reset on read.
float ud_passthrough_take_peak(UDPassthrough *pt);

#endif
