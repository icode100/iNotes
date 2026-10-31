#!/usr/bin/env python3
"""Validate public updater settings and apply them without shell/XML interpolation."""
import base64
import binascii
import os
import plistlib
import sys
from urllib.parse import urlsplit


def settings():
    feed = os.environ.get("UPDATE_FEED_URL", "")
    key = os.environ.get("UPDATE_PUBLIC_ED_KEY", "").strip()
    # Empty settings build a deliberately dormant development updater.
    if not key:
        return {}
    try:
        parsed = urlsplit(feed)
        port = parsed.port  # Reject malformed ports rather than bundling a broken URL.
    except ValueError:
        raise SystemExit("Updater configuration contains an invalid feed URL.")
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, binascii.Error):
        valid_key = False
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.fragment
            or (port is not None and not 1 <= port <= 65535) or not valid_key):
        raise SystemExit("Updater configuration requires an HTTPS feed without credentials and a 32-byte base64 Ed25519 public key.")
    return {
        "SUFeedURL": feed,
        "SUPublicEDKey": key,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUSignedFeedFailureExpirationInterval": 0,
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": True,
        "SUEnableSystemProfiling": False,
        "SUScheduledCheckInterval": 86400,
    }


if __name__ == "__main__":
    config = settings()
    if sys.argv[1:] == ["--validate"]:
        print("Signed automatic update channel configured." if config else "Updater dormant: no release public key configured.")
    elif len(sys.argv) == 2:
        path = sys.argv[1]
        with open(path, "rb") as source:
            info = plistlib.load(source)
        info.update(config)
        with open(path, "wb") as destination:
            plistlib.dump(info, destination)
    else:
        raise SystemExit("Usage: update-config.py --validate | Info.plist")
