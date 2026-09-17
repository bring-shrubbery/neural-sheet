//
//  stb_vorbis.h
//  The one entry point of the vendored stb_vorbis decoder that NeuralSheet uses.
//
//  The implementation lives in stb_vorbis.c (public domain, v1.22). That file
//  carries the library's own full declarations; this header deliberately
//  exposes only the whole-file decode, which is all the Ogg path needs.
//

#ifndef NEURALSHEET_STB_VORBIS_H
#define NEURALSHEET_STB_VORBIS_H

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes a whole Ogg Vorbis file to interleaved 16-bit samples.
///
/// On success `*output` is a malloc'd buffer of `returnValue * *channels`
/// shorts that the caller owns and must `free`. A negative return means the
/// file could not be opened or decoded.
int stb_vorbis_decode_filename(const char *filename, int *channels, int *sample_rate, short **output);

#ifdef __cplusplus
}
#endif

#endif /* NEURALSHEET_STB_VORBIS_H */
