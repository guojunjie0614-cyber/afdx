"""Explicit checker criteria; historical strict checks remain the default."""
import os

LEGACY = 'legacy'
CURRENT = 'fragmentation1030'

def selected():
    value = os.environ.get('AFDX_VERIFICATION_PROFILE', LEGACY)
    if value not in (LEGACY, CURRENT):
        raise ValueError('Unknown AFDX_VERIFICATION_PROFILE: '+value)
    return value
