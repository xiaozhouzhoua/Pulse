#!/usr/bin/env python3
"""Regenerate PulseMac/Resources/Credits.rtf from the license files actually shipped.

The standard About panel shows Credits.rtf from the app bundle. Run this after a
build has resolved packages (it reads their checkouts) and after dependency changes:

    scripts/generate-credits.py [path/to/SourcePackages/checkouts]

The RTF deliberately has no color table, so the About panel draws it in the system
text color and it stays readable in dark mode.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKOUTS = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/SourcePackages/checkouts"
LONGBRIDGE = next((ROOT / ".build/longbridge-sdk").glob("*/openapi"), None)
OUTPUT = ROOT / "PulseMac/Resources/Credits.rtf"

INTRO = (
    "Tick is a modified version of Pulse (https://github.com/fatwang2/Pulse) by fatwang2, "
    "used under the MIT License. Market data comes from third-party providers, is provided "
    "as is, and is for reference only; it is not investment advice."
)

# (heading, files relative to their package root, package root)
COMPONENTS = [
    ("Pulse", ["LICENSE"], ROOT),
    ("TelemetryDeck Swift SDK", ["LICENSE"], CHECKOUTS / "SwiftSDK"),
    ("MCP Swift SDK", ["LICENSE"], CHECKOUTS / "swift-sdk"),
    ("EventSource", ["LICENSE.md"], CHECKOUTS / "eventsource"),
    ("Swift Log", ["LICENSE.txt", "NOTICE.txt"], CHECKOUTS / "swift-log"),
    ("SwiftNIO", ["LICENSE.txt", "NOTICE.txt"], CHECKOUTS / "swift-nio"),
    ("Swift Collections", ["LICENSE.txt"], CHECKOUTS / "swift-collections"),
    ("Swift Atomics", ["LICENSE.txt"], CHECKOUTS / "swift-atomics"),
    ("Swift System", ["LICENSE.txt"], CHECKOUTS / "swift-system"),
    ("Longbridge OpenAPI SDK (MIT License)", ["LICENSE-MIT"], LONGBRIDGE),
    ("Sparkle (direct-download edition only)", ["LICENSE"], CHECKOUTS / "Sparkle"),
]


def escape(text: str) -> str:
    out = []
    for ch in text:
        code = ord(ch)
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\\n")
        elif ch == "\t":
            out.append("\\tab ")
        elif code > 127:
            out.append("\\u%d?" % (code if code < 32768 else code - 65536))
        else:
            out.append(ch)
    return "".join(out)


def main() -> None:
    parts = [
        "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n",
        "{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;\\f1\\fmodern\\fcharset0 Menlo-Regular;}\n",
        "\\pard\\pardirnatural\\partightenfactor0\n",
        "\\f0\\fs20 " + escape(INTRO) + "\\\n\\\n",
    ]
    for heading, files, root in COMPONENTS:
        if root is None:
            sys.exit(f"missing package checkout for {heading}")
        texts = []
        for name in files:
            path = root / name
            if not path.exists():
                sys.exit(f"missing {path}")
            texts.append(path.read_text(encoding="utf-8").strip())
        parts.append("\\f0\\b\\fs22 " + escape(heading) + "\\b0\\fs20 \\\n")
        parts.append("\\f1\\fs16 " + escape("\n\n".join(texts)) + "\\\n\\\n")
    parts.append("}\n")
    OUTPUT.write_text("".join(parts), encoding="ascii")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
