#!/usr/bin/env python3
"""Assert that a DIDL-Lite document is namespaced the way the standards fix it.

Dart's own XML reader tolerates undeclared namespace prefixes: it keeps
`dc:title` as a literal tag name and reports no error, so a broken document
passes the unit tests. libxml2 prints "Namespace prefix dc is not defined" but
still exits 0 under `--noout`, which would not fail a build either. ElementTree
raises on an unbound prefix and resolves the Clark-notation names, so this is
the independent check that actually gates the release pipeline.
"""

import sys
import xml.etree.ElementTree as ET

DIDL = "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
DC = "http://purl.org/dc/elements/1.1/"
UPNP = "urn:schemas-upnp-org:metadata-1-0/upnp/"

REQUIRED = [
    (".//{%s}title" % DC, "dc:title must resolve under the Dublin Core namespace"),
    (".//{%s}class" % UPNP, "upnp:class must resolve under the UPnP metadata namespace"),
    (".//{%s}res" % DIDL, "res must resolve under the DIDL-Lite namespace"),
]


def main() -> int:
    document = sys.stdin.read()
    try:
        root = ET.fromstring(document)
    except ET.ParseError as error:
        print("DIDL-Lite is not strictly well-formed: %s" % error, file=sys.stderr)
        return 1
    if root.tag != "{%s}DIDL-Lite" % DIDL:
        print(
            "unexpected root %r; expected the DIDL-Lite namespace %r"
            % (root.tag, DIDL),
            file=sys.stderr,
        )
        return 1
    for path, reason in REQUIRED:
        if root.find(path) is None:
            print("%s (%s)" % (reason, path), file=sys.stderr)
            return 1
    res = root.find(".//{%s}res" % DIDL)
    protocol = res.get("protocolInfo", "")
    if not protocol.startswith("http-get:"):
        print("res protocolInfo must start with http-get: %r" % protocol, file=sys.stderr)
        return 1
    print(
        "DIDL-Lite verified by an independent parser: root %s, res mime %s"
        % (root.tag, protocol.split(":")[2].split(";")[0])
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
