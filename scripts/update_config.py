"""Public Sparkle configuration shared by build and release preparation."""
import base64
import json
import os
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / 'Resources' / 'UpdateConfiguration.json'


def load_configuration(environment=None, config_path=CONFIG_PATH):
    environment = os.environ if environment is None else environment
    with open(config_path, encoding='utf-8') as source:
        config = json.load(source)
    feed_override = environment.get('LOOKOUT_UPDATE_FEED_URL', '').strip()
    key_override = environment.get('LOOKOUT_UPDATE_PUBLIC_KEY', '').strip()
    if bool(feed_override) != bool(key_override):
        raise ValueError('Both LOOKOUT_UPDATE_FEED_URL and LOOKOUT_UPDATE_PUBLIC_KEY are required for an override.')
    if environment.get('LOOKOUT_DISABLE_UPDATES') == '1':
        if feed_override or key_override:
            raise ValueError('Do not combine LOOKOUT_DISABLE_UPDATES with update configuration overrides.')
        config['feedURL'] = config['publicKey'] = ''
        return config
    if feed_override:
        config['feedURL'], config['publicKey'] = feed_override, key_override
    feed, key = config.get('feedURL', '').strip(), config.get('publicKey', '').strip()
    try:
        url = urlsplit(feed)
        valid_url = url.scheme.lower() == 'https' and bool(url.hostname) and url.username is None and url.password is None and '#' not in feed
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_url = valid_key = False
    if not valid_url or not valid_key:
        raise ValueError('Use a valid HTTPS feed URL and a base64 Ed25519 public key (32 bytes).')
    config['feedURL'], config['publicKey'] = feed, key
    return config
