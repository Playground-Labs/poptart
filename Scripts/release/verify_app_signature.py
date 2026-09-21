#!/usr/bin/env python3
"""Check the shipping app's signing policy before contacting Apple's notary service."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def verify(app, team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("an expected 10-character Apple Developer Team ID is required")
    requirement = ('=identifier "labs.playground.Poptart" and anchor apple generic '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
                   f'and certificate leaf[subject.OU] = "{team}"')
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", requirement,
                    str(app)], check=True)
    details = subprocess.run(["codesign", "--display", "--verbose=4", str(app)],
                             check=True, capture_output=True, text=True).stderr
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", details)
    if not flags or not int(flags[1], 16) & 0x10000:
        raise ValueError("hardened runtime is required")
    if not re.search(r"^Timestamp=.+$", details, re.MULTILINE):
        raise ValueError("a secure signing timestamp is required")
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    if (not isinstance(entitlements, dict)
            or set(entitlements) != {"com.apple.security.device.audio-input"}
            or entitlements["com.apple.security.device.audio-input"] is not True):
        raise ValueError("only the Audio Input entitlement is approved for this release")


if __name__ == "__main__":
    if len(sys.argv) != 3 or not Path(sys.argv[1]).is_dir():
        sys.exit("usage: verify_app_signature.py SIGNED_APP EXPECTED_TEAM_ID")
    try:
        verify(Path(sys.argv[1]), sys.argv[2])
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"application signing verification failed: {error}")
    print("Developer ID, hardened runtime, timestamp and entitlements verified")
