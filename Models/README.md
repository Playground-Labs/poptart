# Managed Model release metadata

The practical MVP Cleanup candidate is `Artifacts/diverse-contexts-step128`: a separate F32 LoRA
adapter on the pinned four-bit Qwen 3.5 2B base. ADR 0054 supersedes the earlier 0.8B decision.
The retained decision evidence is
`../Training/experiments/practical-candidate-decision-2026-09-18.json`. This is a development
candidate, not a release-qualified or published Model Pack.

`production-config.json` is the single machine-readable declaration of the exact runtimes and model choices implemented by Poptart. Its `unreleased` state is deliberate: artifact sizes, hashes, the Cleanup token ceiling, quality evidence, and exact physical benchmark platform must come from real release artifacts and measurements. The beta baseline is an M5 Pro; the config explicitly leaves 8 GB M1 performance unverified.

`model-pack.example.json` demonstrates the manifest shape but is intentionally invalid for installation. Release tooling refuses null evidence and the `exampleOnly` marker. No model weights are stored in Git.

The Qwen 3.5 2B base revision is pinned to `15852e8c16360a2fea060d615a32b45270f8a8fc` and is Apache-2.0 licensed. FluidAudio and Parakeet artifacts must retain their upstream notices when packaged.


Recognition weights are pinned separately from the Apache-2.0 FluidAudio SDK:
[FluidInference Parakeet Unified](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/tree/4252711f6f060f9a2f91e5f081a806d7f45eebd8)
revision `4252711f6f060f9a2f91e5f081a806d7f45eebd8` declares **CC-BY-4.0**.
The earlier Apache-2.0 artifact metadata was incorrect. Include attribution to NVIDIA for
Parakeet and FluidInference for the Core ML conversion/integration, the upstream source URL,
the [license link](https://creativecommons.org/licenses/by/4.0/), and an indication of any
changes with distributed packs. Current staging selects the 70/7/1 int8 encoder, decoder,
joint-decision bundle, vocabulary and metadata without modifying their bytes.

## Installation trust and recovery

Pack/application versions use numeric dotted release components; prerelease suffixes are not
accepted. Only one installation transaction runs at a time. Downloads enforce their declared
byte bound while receiving data, and resume only against a matching local partial-file offset.

Activation retains the publisher-signed manifest. Startup verifies that signature and requires
local metadata and artifact hashes to match. If mutable metadata is damaged, explicit Repair
can restore the same or a newer signed version using the retained authenticated version floor.
If the signed envelope itself is absent or damaged, automatic repair refuses to forget that
floor. Unsigned experimental activation records from earlier development builds cannot establish
release trust; restore trusted activation data rather than editing hashes or version fields.


Recognition uses the [Poptart FluidAudio fork](https://github.com/brandon-nextwork/FluidAudio)
at `61dc8edf915e528a11d81ded84b83d2709746713`, based on upstream 0.15.6. The metadata label
`0.15.6-poptart.2` identifies this two-fix variant, not an upstream release tag. The fixes retain
the verified local CTC tokenizer directory and let Poptart disable SDK transcript/vocabulary
logging before recognition begins. Both package lockfiles must resolve this exact fork commit.


Model Packs contain signed individual runtime files, including nested Core ML bundle contents.
Production metadata groups files by role; recognition includes optional root-level `vad/` files.
`byteSize` is the aggregate size and `sha256` is its canonical pack-relative file-inventory digest, as specified in
[the publication commands](../Scripts/README.md#per-file-model-pack-publication). Each manifest
entry has its own file hash and size. The app downloads directly into the required layout and
verifies those same files on startup; archives are not an installable model format.

The optional `vad/` component is pinned separately in `recognition.vad`: FluidInference's
[Silero conversion](https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96),
revision `b419383c55c110e2c9271fa6ee0ea83d03c70d96`, bundle
`silero-vad-unified-256ms-v6.2.1.mlmodelc`. Its license is MIT, not Parakeet's CC-BY-4.0.
Copy [the Silero license](notices/Silero-LICENSE.txt) into `vad/LICENSE.txt` before creating the
manifest. The generator and signing verifier check each file's license against its component.
Missing or unloadable VAD still leaves recognition usable; staging files alone does not prove
the detector loaded or correctly distinguished speech from noise.

Cleanup supports either the original flat fused-model directory or one quantized base with its
separate trained LoRA adapter:

```text
cleanup/
  base/       config.json, tokenizer files, model safetensors and index
  adapters/   adapter_config.json, adapters.safetensors
```

Both trees belong to the same Cleanup model and signed inventory. MLX recursively reads weight
files, so the base loader receives only `base/`; the trained adapter is applied afterward without
requantizing its updates. The loader rejects partial layouts, empty adapters, missing/extra tensors,
and shape mismatches. Flat artifacts remain usable for historical comparisons. Native evaluation
and release verification hash both trees, including the adapter configuration.

The [retained asset smoke](evidence/silero-vad-2026-09-16.json) verifies upstream file hashes and
CPU-only inference on silence, seeded white noise and one synthesized speech fixture. A separate
production SpeechGate probe, using its CPU/Neural Engine configuration and misaligned 1,536-frame
capture buffers, zeroed all 32,768 noise frames and preserved all 34,651 synthesized speech frames.
The evidence includes the probe source and log. This establishes that the staged model loads and
the production gate executes; it does not establish representative human speech/noise accuracy
or which compute device Core ML selected.

The [real Personal Vocabulary diagnostic](evidence/vocabulary-assets-2026-09-16.json) exercised
these pinned recognition/CTC assets through the production adapter. For two synthetic recordings,
adding `MapleKrest` or `LindenHarbor` changed recognition to that exact spelling; removing the term
restored the original transcript. All six runs finalized inside a network-denied subprocess.
The evidence retains model, audio, source and test-binary hashes. This establishes the observed
vocabulary addition/removal behavior, not general recognition quality, active VAD, human speech,
M1 latency, or a full privacy pass. The CTC model-card license ambiguity remains unresolved.

A [prepared recorded-human-speech probe](evidence/public-speech-inputs-2026-09-17.json) selects
16 LibriSpeech test-clean clips from eight readers before inference: the first four numeric
reader IDs in each published F/M metadata group, then the first two utterances per reader.
The official archive checksum, CC-BY-4.0 attribution, individual audio hashes, decoder command,
reference transcripts, build-time source/pin hashes, and retained test runner are recorded.
The clips total 137.995 seconds. Audio remains local and is not shipped with the application.

The [completed probe](evidence/public-speech-2026-09-17.json) uses production RecognitionService
replay, empty Personal Vocabulary, and a diagnostic 30-second finalization allowance. All 16
clips finalized under an IP-denying sandbox after IPv4/IPv6 EPERM controls. All produced hypotheses
before replay release; 12/16 transcripts matched after the declared case/punctuation normalization.
Aggregate word error rate was 6/361 (1.66%), with no number, spelling, or reference-specific rewriting.
First hypotheses arrived 1,328–1,856 ms after the pre-start clock reading (including recognizer setup);
release-to-finalization was 249–625 ms on the M5 Pro. These are recognition-only observations.

Both independent reviews cleared the source and evidence bindings. This small ordered audiobook
sample is not representative live Dictation, an independent ASR benchmark (upstream training overlap
is unknown), the physical release baseline, or a full network/privacy test. No Cleanup, insertion, or history
path runs in this probe. Original audio, predictions, and errors remain unchanged in the evidence.

The [paired VAD comparison](evidence/public-speech-vad-comparison-2026-09-17.json) replayed these
same 16 clips with the detector enabled, then disabled. DEBUG-only observations verified the
requested detector state before and after every clip, including detection of runtime fail-open.
All 16 final transcripts were byte-identical between modes: both had 6/361 word errors and
pre-release hypotheses for every clip. This provides no evidence to disable the production gate.
The retained runs bind the same models, audio, sources, and runner, and the disabled run binds the
completed enabled result. One ordered pair on an M5 Pro with uncontrolled cache conditions does
not establish a timing improvement or noisy-speech performance; the earlier scope limits apply.

## M5 Pro beta performance baseline

The [physical M5 Pro benchmark](evidence/m5-pro-beta-benchmark-2026-09-21.json) runs the selected
Cleanup adapter with the staged recognition/VAD/CTC assets and all 12 authored audio fixtures through
the real Dictation coordinator, controlled delivery, and encrypted history readback. The report binds
the exact hardware, macOS version, runner/source, manifest, model files, fixtures, and audio. It is the
MVP beta performance baseline under ADR 0055. Controlled delivery excludes live Accessibility
insertion, the pack is an unsigned development pack, and 8 GB M1 performance remains unverified.
