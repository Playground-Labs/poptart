# Poptart

Poptart is a native macOS, local-first voice keyboard. Hold the dictation shortcut, speak, and release to insert the result into the focused text field. When no editable field is available, Poptart copies the result to the clipboard.

This is the canonical Swift repository. The earlier Handy-derived Tauri application and its development history are preserved in [poptart-legacy](https://github.com/Playground-Labs/poptart-legacy), as decided in [ADR 0035](adr/0035-give-the-redesign-the-canonical-repository-name.md).

## Development

Requires macOS 15 or later, Apple Silicon, and an Xcode toolchain supporting Swift 6.2 or later.

```sh
swift build --product Poptart
swift test
```

To launch a development build whose permission grants survive a rebuild, use `Scripts/dev-run.sh`, which wraps the executable in an ad-hoc-signed application bundle.

Run package-level tests separately; the root test command covers application integration tests:

```sh
for package in DictationCore Persistence ModelRuntime Cleanup Recognition SystemIntegration; do
  swift test --package-path "Packages/$package" || exit 1
done
```

Running dictation also requires local recognition and Cleanup model assets and the macOS Microphone, Accessibility, and Input Monitoring permissions. Model weights and development bundles are not committed. See [Models](Models/README.md) for model-pack metadata and [release tooling](Scripts/README.md) for validation and packaging. Production model-pack artifacts and release qualification remain in progress.

## Project guide

- [SPEC.md](SPEC.md): implementation specification and release gates.
- [PRODUCT-SPEC.md](PRODUCT-SPEC.md): product behavior and scope.
- [CONTEXT.md](CONTEXT.md): domain vocabulary.
- [adr/](adr/): architectural decisions.
- [FOLLOW-UPS.md](FOLLOW-UPS.md): future work, including dominant-speaker isolation without a retained voiceprint.

Application composition and macOS UI live in `App/`. Local Swift packages in `Packages/` own dictation policy, recognition, Cleanup, system integration, model management, and persistence.

## License

[MIT](LICENSE), per [ADR 0031](adr/0031-license-the-new-codebase-under-mit.md). Upstream attribution is retained; bundled dependencies and model assets retain their respective licenses.
