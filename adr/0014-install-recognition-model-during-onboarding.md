# Install the recognition model during onboarding

Poptart will install its managed recognition model during onboarding from a Playground Labs-controlled, checksummed manifest rather than embedding it in the signed application bundle. Downloads must be resumable, and after installation the model operates locally without a network connection; a complete offline installer is deferred.
