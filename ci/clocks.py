#!/usr/bin/env python3
"""Library code and unit tests have no clock; timed work lives on bench.

Check every source file, including test helpers, so moving a timing loop
behind a helper cannot put a speed assertion back into the unit suite.
Comments and strings are ignored by the same lexer the cast check uses.
"""

import pathlib
import re
import sys

from casts import code_of


CLOCK = re.compile(
    r"\b(Clock|Timer|Instant|nanoTimestamp|microTimestamp|milliTimestamp|"
    r"timestamp|clock_gettime|gettimeofday|mach_absolute_time|"
    r"QueryPerformanceCounter|sleep)\b"
)


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    found = []
    for path in sorted((root / "src").rglob("*.zig")):
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if CLOCK.search(code_of(line)):
                found.append(f"{path.relative_to(root)}:{n}: {line.strip()}")
    for finding in found:
        print(f"{finding}  <- clocks belong on the bench branch", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
