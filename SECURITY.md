# Security policy

NeuralSheet runs entirely on your Mac. It goes online only to download model files from Hugging Face and to check GitHub for a newer release; your audio never leaves the machine.

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private reporting form:

https://github.com/bring-shrubbery/neural-sheet/security/advisories/new

Include what you found, how to reproduce it, and the NeuralSheet version or commit. You will get an acknowledgement within a few days and a fix or a reasoned response as soon as we have one. We will credit you in the release notes unless you ask us not to.

## Scope

In scope: the NeuralSheet app and its Swift package, the C bridge to the transcription engine, the build scripts and GitHub workflows in this repository.

Out of scope: the upstream transcription engine [muscriptor.cpp](https://github.com/DamRsn/muscriptor.cpp) and [ggml](https://github.com/ggml-org/ggml) (report there), the MuScriptor model itself, and Hugging Face.

## Supported versions

Only the latest release, and `main`, receive security fixes.
