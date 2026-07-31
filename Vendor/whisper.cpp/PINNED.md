# whisper.cpp vendor pin

The production ASR adapter uses a locally built `whisper-cli`, not a bundled
binary. This file pins the intended upstream baseline:

- Repository: `https://github.com/ggml-org/whisper.cpp.git`
- Tag: `v1.8.3`
- Commit: `2eeeba56e9edd762b4b38467bab96c2517163158`

Run `Scripts/bootstrap.sh --fetch-whisper` to create a local checkout at this
exact revision, then `Scripts/build_whisper_xcframework.sh` to build the CLI.
The checkout and all generated artifacts are ignored by Git; model weights must
remain outside the repository.
