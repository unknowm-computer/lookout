#!/usr/bin/env python3
"""Inject only public update configuration into the built app's Info.plist."""
import plistlib
import sys
from update_config import load_configuration

try:
    config = load_configuration()
except (ValueError, OSError) as error:
    sys.exit(str(error))
feed, key = config['feedURL'], config['publicKey']
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
