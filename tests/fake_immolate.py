#!/usr/bin/env python3
"""A stand-in for the Immolate binary, for deterministic watcher tests (no GPU).

The watcher invokes it exactly as the real searcher:
    fake_immolate.py -f <filter> --first -q -s random -j <query>

Behaviour is selected by env var FAKE_MODE:
    seed   (default) -> print a fixed seed (success)
    multi            -> print several lines (watcher must take the first)
    empty            -> print nothing, exit 0  (no matching seed)
    fail             -> write stderr, exit 1    (search error)

Every invocation appends its argv (one JSON line) to $FAKE_LOG if set, so tests
can spy on how many times -- and with what query -- the watcher ran it.
"""

import json
import os
import sys

FIXED_SEED = "FAKESEED"


def main() -> int:
    log = os.environ.get("FAKE_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as f:
            f.write(json.dumps(sys.argv[1:]) + "\n")

    mode = os.environ.get("FAKE_MODE", "seed")
    if mode == "fail":
        sys.stderr.write("simulated search failure\n")
        return 1
    if mode == "empty":
        return 0
    if mode == "multi":
        print(FIXED_SEED)
        print("SECONDONE")
        return 0
    print(FIXED_SEED)
    return 0


if __name__ == "__main__":
    sys.exit(main())
