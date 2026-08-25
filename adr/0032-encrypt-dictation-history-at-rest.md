# Encrypt Dictation history at rest

Poptart will encrypt sensitive Dictation Record fields at the application level using CryptoKit and a per-install encryption key stored in macOS Keychain. Only non-sensitive metadata needed for ordering and outcome filtering may remain queryable in plaintext; losing the Keychain key makes existing encrypted history unrecoverable rather than introducing a remote recovery service.
