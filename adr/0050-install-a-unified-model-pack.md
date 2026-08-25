# Install a unified model pack

Onboarding will install recognition and Cleanup artifacts together as one versioned Managed Model pack. Poptart downloads the pack from a Playground Labs-controlled signed manifest, verifies each artifact's checksum and license metadata, stages the full pack, and activates it atomically only after every component is valid. This prevents incompatible recognition and Cleanup combinations and gives onboarding one offline-readiness result. Future pack downloads require an explicit user action and use the same staged activation and rollback-safe validation.
