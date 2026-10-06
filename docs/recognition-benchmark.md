# Recognition qualification (ADR 0051)

Start with an exploratory replay against the production `FluidAudioIncrementalRecognizer`.
The opt-in XCTest harness uses the same pinned FluidAudio dependency, 70/7/1 int8
configuration, speech gate, vocabulary adapter, and finalization deadline as the app.
It does not download models, capture the microphone, or read private app data.

## Run a local replay

1. Stage the exact local recognition assets and an explicitly licensed test speech
   corpus. Use nonempty 16 kHz mono audio readable by AVFoundation. Keep audio,
   models, manifests, and reports outside Git (for example under `.context/`).
   Do not use retained user Dictations. Record corpus source, license, artifact
   revision, and hashes alongside the results.
2. Create a JSON manifest. Paths are relative to the manifest, or absolute:

   ```json
   {
     "modelDirectory": "models/unified",
     "ctcDirectory": null,
     "vadDirectory": null,
     "repetitions": 3,
     "output": "recognition-report.json",
     "fixtures": [
       {
         "id": "short-sentence",
         "audio": "speech/short-sentence.wav",
         "reference": "The package arrives on Tuesday.",
         "vocabulary": []
       }
     ]
   }
   ```

   Supply the production VAD directory when assessing gated recognition. A missing
   or unloadable VAD fails open in the production adapter, so a supplied path alone
   does not prove the VAD loaded. Vocabulary fixtures require a CTC directory;
   compare the same recording with and without vocabulary entries.
3. From the repository root, run:

   ```sh
   POPTART_RECOGNITION_BENCHMARK="$PWD/.context/replay.json" \
     swift test -c release --package-path Packages/Recognition \
       --filter RecognitionBenchmarkTests/testReplayLocalSpeech
   ```

   Without the environment variable the replay test explicitly skips. A configured
   run fails on missing assets, bad input, or an unwritable output. A successful
   test means the experiment ran and wrote a report, **not** that quality passed.

## Read the report

- `prepareMilliseconds` measures initial model preparation separately. Replays use
  prepared models; the first inference can still include lazy runtime warm-up.
- `firstPartialMilliseconds` measures observation of the first nonblank callback
  relative to audio start. An absent field means no partial was observed. A callback
  after key-up is not evidence of timely incremental recognition.
- `keyUpToResultMilliseconds` includes inference backlog after the recording's
  scheduled end and finalization/reset. Audio arrives in 100 ms chunks paced against
  one monotonic origin. Slow inference cannot postpone the simulated key-up or
  receive a fresh deadline after draining its backlog.
- Each row retains `outcome`, reference, transcript, and normalized word error rate.
  WER ignores case and splits on nonletters/nonnumbers; inspect punctuation,
  capitalization, vocabulary, and meaning separately. A fast fallback is not a
  successful final transcript. Failed rows stay in the report.
- `processPeakResidentBytes` is macOS `getrusage` peak RSS for the entire XCTest
  process, including the harness, decoded fixtures, and dependencies. It is not
  app steady-state memory or both-model residency.
- Hardware, OS, local model paths, and iteration are recorded. Reports always say
  `releaseQualified: false`; they carry no automatic release pass judgment.

## Remaining release qualification

Run on a physical **8 GB Apple M1 with macOS 15 or newer**, using the exact production
artifact and a representative, provenance-recorded English speech corpus. Capture
artifact hashes and a reproducible cold-system setup. Include short and long
utterances, silence/noise, vocabulary pairs, and difficult speech; this starter
harness accepts speech references and does not yet score silence/noise-only cases.
Repeated playback of one sentence is not a representative release sample.

ADR 0051 requires first-partial timing, final recognition quality, vocabulary,
key-up-to-final timing, and memory evidence. Record explicit acceptance criteria
for quality and partial latency before selecting the artifact; the ADR does not
supply numerical thresholds for those measures.

The 1.5 second p99 gate applies to **key-up through delivery**, including Cleanup
and insertion, on the full application. This replay covers only recognition.
Full qualification still needs microphone/capture integration, both models resident,
steady-state and peak memory, memory-pressure reload, recognition/Cleanup timeouts,
oversized input, and target-change delivery. Keep OS-wide stalls separate from
app-controlled misses. The existing `Scripts/benchmark_release.py` consumes Cleanup
text fixtures and is not a recognition or full-application runner.

If the production Parakeet artifact fails these gates, ADR 0051 calls for evaluating
FluidAudio Nemotron Streaming 560 next; do not weaken the completion deadline.
