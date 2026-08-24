/* SPDX-License-Identifier: AGPL-3.0-only
 *
 * The C ABI of the companion wakeword engine.
 *
 * Implemented by `companion-wakeword-ffi` (static library
 * `libcompanion_wakeword_ffi.a`). The engine behind it is `companion-wakeword`: an MFCC
 * frontend and a subsequence-DTW template matcher, trained from a few recordings of the
 * word. Nothing here talks to the network and nothing here starts a thread.
 *
 * Written by hand rather than generated with cbindgen. The reasons, so the next person does
 * not have to rediscover them:
 *
 *   - The surface is eight functions and one struct, and it is meant to stay that way. A
 *     generator earns its keep on an ABI that grows with the crate; this one is a deliberate
 *     narrow door.
 *   - The contract that matters is in the comments — who owns which pointer, what a negative
 *     return means, which call resets the stream. cbindgen would carry the doc comments over
 *     but not the decision of what belongs here, so the file would be hand-edited anyway,
 *     and a hand-edited generated file is the worst of both.
 *   - The public repository would otherwise gain a build-time code generator plus a checked-in
 *     artefact that has to be regenerated in lockstep, for sixty lines of declarations.
 *
 * What that costs, stated plainly: a signature can drift between this file and the Rust side
 * without the compiler noticing, because C believes the header. Two things guard it. A
 * renamed or removed function is a link error, since the Swift module links the static
 * library. A deliberate change of shape is caught by COMPANION_WAKEWORD_ABI_VERSION below,
 * which every caller checks against companion_wakeword_abi_version() before the first call.
 * A silent change of a parameter type is caught by neither; changing one without raising the
 * version is the mistake this comment exists to prevent.
 */

#ifndef COMPANION_WAKEWORD_H
#define COMPANION_WAKEWORD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Raised on every change to a signature, a struct layout, or the meaning of a return value.
 * The library reports its own with companion_wakeword_abi_version(). */
#define COMPANION_WAKEWORD_ABI_VERSION 1u

/* Every entry point takes and returns 16 kHz mono signed 16-bit audio. Resampling belongs to
 * the capture side. */
#define COMPANION_WAKEWORD_SAMPLE_RATE 16000u

/* One detection. Plain data, copied out by value. */
typedef struct {
    /* Per-step DTW distance of the template that matched; smaller is closer. */
    float score;
    /* Which loaded word fired, in the order the models were loaded. */
    uint32_t model_index;
    /* Stream position, in samples since the first feed on this handle. */
    uint64_t at_sample;
} CompanionWakewordDetection;

/* The detector. Opaque; a handle belongs to one thread at a time. */
typedef struct CompanionWakewordDetector CompanionWakewordDetector;

/* The ABI version of this library. Check it against COMPANION_WAKEWORD_ABI_VERSION before
 * the first call. */
uint32_t companion_wakeword_abi_version(void);

/* The last failure on the calling thread, or NULL when the last call succeeded. The string
 * belongs to the library and stays valid until the next failing call on the same thread. */
const char *companion_wakeword_last_error(void);

/* Creates a detector with no words in it. Never returns NULL. */
CompanionWakewordDetector *companion_wakeword_create(void);

/* Frees a handle. NULL is allowed and does nothing. */
void companion_wakeword_destroy(CompanionWakewordDetector *detector);

/* Loads a trained word from a model file and adds it to the handle. Returns the index of the
 * loaded word, or -1 on failure. Loading restarts the audio stream. */
int32_t companion_wakeword_load_model(CompanionWakewordDetector *detector, const char *path);

/* How many words are loaded, or -1 for a NULL handle. */
int32_t companion_wakeword_model_count(const CompanionWakewordDetector *detector);

/* The name of a loaded word, or NULL when the index is out of range. The string belongs to
 * the handle and is valid until it is destroyed. */
const char *companion_wakeword_model_name(const CompanionWakewordDetector *detector,
                                          uint32_t index);

/* Forgets the audio stream without touching the loaded words. Call it when listening stops
 * and again when it resumes: the gap between the two is audio the detector never saw. */
void companion_wakeword_reset(CompanionWakewordDetector *detector);

/* Feeds 16 kHz mono PCM16 and reports what it completed.
 *
 * Returns how many detections this call produced, or -1 on a bad argument. When `out` is not
 * NULL it receives the FIRST of them. `sample_count` counts samples, not bytes; zero is
 * allowed and does nothing. */
int32_t companion_wakeword_feed(CompanionWakewordDetector *detector, const int16_t *pcm,
                                size_t sample_count, CompanionWakewordDetection *out);

/* Trains a word from recordings and writes the model file.
 *
 * `wav_paths` points at `count` paths to 16 kHz mono PCM16 WAV files — the takes of the word,
 * three to five of them. The model is written to `out_path`, whose directory has to exist.
 * Returns 0 on success and -1 on failure. Synchronous; keep it off a thread that is drawing. */
int32_t companion_wakeword_train(const char *name, const char *const *wav_paths, size_t count,
                                 const char *out_path);

#ifdef __cplusplus
}
#endif

#endif /* COMPANION_WAKEWORD_H */
