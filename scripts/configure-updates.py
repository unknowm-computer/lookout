#!/usr/bin/env python3
"""Inject only public update configuration into the built app's Info.plist."""
import base64
import os
import plistlib
import sys
from urllib.parse import urlsplit

feed = os.environ.get('LOOKOUT_UPDATE_FEED_URL', '').strip()
key = os.environ.get('LOOKOUT_UPDATE_PUBLIC_KEY', '').strip()
if bool(feed) != bool(key):
    sys.exit('Both LOOKOUT_UPDATE_FEED_URL and LOOKOUT_UPDATE_PUBLIC_KEY are required.')
if feed:
    try:
        url = urlsplit(feed)
        valid_url = url.scheme.lower() == 'https' and bool(url.hostname) and url.username is None and url.password is None and '#' not in feed
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_url = valid_key = False
    if not valid_url or not valid_key:
        sys.exit('Use a valid HTTPS feed URL and a base64 Ed25519 public key (32 bytes).')
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
info.pop('SUFeedURL', None)
info.pop('SUPublicEDKey', None)
if feed:
    info['SUFeedURL'] = feed
    info['SUPublicEDKey'] = key
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(info, destination)
print('Update feed configured.' if feed else 'Update feed not configured; updater remains inactive.')
