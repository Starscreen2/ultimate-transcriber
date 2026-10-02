# Third-party notices

Speaker Marks uses or can download software and model files maintained by third parties. Their names and marks belong to their respective owners. This project is not affiliated with those upstream projects.

## Software built into the macOS app

| Component | License | Source |
| --- | --- | --- |
| whisper.cpp | MIT | <https://github.com/ggml-org/whisper.cpp> |
| sherpa-onnx | Apache-2.0 | <https://github.com/k2-fsa/sherpa-onnx> |
| ONNX Runtime (statically linked through sherpa-onnx) | MIT; includes additional notices | <https://github.com/microsoft/onnxruntime> |
| sherpa-onnx build dependencies: Eigen, Kaldi decoder, Kaldi native fbank, kaldifst, OpenFST, KissFFT, nlohmann/json, hclust_cpp, and simple-sentencepiece | See included license and notice files | Upstream project links are listed in the corresponding license files and sherpa-onnx build configuration |

The upstream license texts and ONNX Runtime third-party notices are included in `ThirdPartyLicenses/` and copied into the app bundle by `build-app.sh`.

## Software installed separately

FFmpeg is used for media conversion when available on the user's Mac; it is not bundled by this project. Install it separately with Homebrew (`brew install ffmpeg`). FFmpeg builds can use different configurations and licenses; consult the license information for the specific FFmpeg build you install.

## Models downloaded by the app

Model weights are downloaded on demand from their upstream hosts and are not included in this source repository or release bundle. The app currently downloads Whisper model files from [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp), VAD model files from [ggml-org/whisper-vad on Hugging Face](https://huggingface.co/ggml-org/whisper-vad), and optional speaker-diarization files from [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases). Each model remains subject to its own upstream license, access conditions, and attribution requirements. Review the source page for the particular model before redistribution or other use.

The upstream pages currently identify the Whisper and whisper-vad model repositories as MIT licensed. The pyannote segmentation model page also identifies its model as MIT licensed, but access to the model may require accepting its current access conditions. These model terms are separate from the licenses for whisper.cpp and sherpa-onnx software.

## Notices

This notice is informational and is not legal advice. See each upstream project and model page for the authoritative license and terms.
