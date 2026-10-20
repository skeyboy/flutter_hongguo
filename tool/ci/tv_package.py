#!/usr/bin/env python3
"""Decide whether an aapt2 badging dump describes an installable Android TV app."""
import re


def _value(pattern, text):
    match = re.search(pattern, text, re.M)
    return match.group(1) if match else None


def badging_problems(badging, app_id_suffix='.tv'):
    """Return human-readable reasons the APK is not a TV build; empty means publishable."""
    package = _value(r"^package: name='([^']*)'", badging)
    if package is None:
        return ['badging output has no package line, so the APK could not be read']
    problems = []
    if app_id_suffix and not package.endswith(app_id_suffix):
        problems.append(f'{package} is not the TV applicationId (expected suffix {app_id_suffix})')
    if not _value(r"^application: .* banner='([^']*)'", badging):
        problems.append('the application declares no android:banner, so TV home screens cannot list it')
    launcher = _value(r"^launchable-activity: name='([^']*)'", badging)
    leanback = _value(r"^leanback-launchable-activity: name='([^']*)'", badging)
    if leanback is None:
        problems.append('no LEANBACK_LAUNCHER activity, so the app is unreachable on Android TV')
    elif launcher and leanback != launcher:
        problems.append(f'LEANBACK_LAUNCHER {leanback} is not the phone launcher {launcher}')
    if "uses-feature: name='android.software.leanback'" not in badging:
        problems.append('android.software.leanback is not required, so non-TV devices may install it')
    if "uses-feature-not-required: name='android.hardware.touchscreen'" not in badging:
        problems.append('android.hardware.touchscreen is still required, which excludes TV devices')
    return problems
