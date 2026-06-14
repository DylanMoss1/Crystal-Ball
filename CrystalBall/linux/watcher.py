#!/usr/bin/env python3
"""Crystal Ball watcher - bridges the Balatro mod to the Immolate searcher.

Polls <dir>/request.txt for a new request id, runs Immolate with the query, and
writes <dir>/response.txt. Runs on the host OS (Linux or Windows).

Handshake files (line-based, no JSON parsing needed here):
    request.txt :  <id>\\n<query-json>\\n
    response.txt:  <id>\\n<seed-or-ERROR>\\n

Example (Proton/Linux):
    python3 watcher.py \\
      --immolate ../Immolate/Immolate \\
      --dir "$HOME/.local/share/Steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/CrystalBallBackendCommunication"
"""

import argparse
import os
import subprocess
import time


def run_immolate(binary, filt, query, timeout):
    """returns: (seed, None) on success, or (None, error_message)."""
    cmd = [binary, "-f", filt, "--first", "-q", "-j", query]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:  # noqa: BLE001 - report any spawn/timeout failure verbatim
        return None, str(e)
    if proc.returncode != 0:
        return None, (proc.stderr.strip() or f"exit {proc.returncode}")
    seed = (proc.stdout or "").strip().split("\n")[0].strip()
    return (seed, None) if seed else (None, "no matching seed")


def main():
    ap = argparse.ArgumentParser(description="Crystal Ball <-> Immolate bridge")
    ap.add_argument(
        "--dir", required=True, help="CrystalBall handshake dir (in the LOVE save dir)"
    )
    ap.add_argument("--immolate", required=True, help="path to the Immolate binary")
    ap.add_argument("--filter", default="find_joker")
    ap.add_argument("--interval", type=float, default=0.5, help="poll seconds")
    ap.add_argument("--search-timeout", type=float, default=600.0)
    args = ap.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    req_path = os.path.join(args.dir, "request.txt")
    resp_path = os.path.join(args.dir, "response.txt")

    if os.path.exists(req_path):
        os.remove(req_path)

    if os.path.exists(resp_path):
        os.remove(resp_path)

    last_id = None
    print(f"[CrystalBall] watching {req_path}\n[CrystalBall] immolate: {args.immolate}")

    while True:
        try:
            with open(req_path, "r", encoding="utf-8") as f:
                head = f.read().split("\n", 1)
        except FileNotFoundError:
            time.sleep(args.interval)
            continue

        if len(head) < 2 or not head[0].strip():
            time.sleep(args.interval)
            continue

        rid, query = head[0].strip(), head[1].strip()
        if rid == last_id:
            time.sleep(args.interval)
            continue
        last_id = rid

        seed, err = run_immolate(args.immolate, args.filter, query, args.search_timeout)
        payload = seed if seed else f"ERROR: {err}"

        # Atomic write so the mod never reads a half-written file.
        tmp = resp_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(f"{rid}\n{payload}\n")
        os.replace(tmp, resp_path)
        print(f"[CrystalBall] {rid} -> {payload}")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
