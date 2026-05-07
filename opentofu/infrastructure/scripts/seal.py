#!/usr/bin/env python3
"""
Seal a single value against a GitHub repository public key, ready
for the GitHub Actions secret `encrypted_value` field.

Invoked as an `external` data source in OpenTofu — reads a JSON
object from stdin with `public_key` (base64) and `plaintext`, writes
a JSON object to stdout with `ciphertext` (base64).

Requires `pynacl` (`pip install --user --break-system-packages pynacl`
or your system's equivalent).
"""
import base64
import json
import sys

from nacl import encoding, public


def main() -> None:
    query = json.load(sys.stdin)
    pk = public.PublicKey(query["public_key"], encoding.Base64Encoder())
    ct = public.SealedBox(pk).encrypt(query["plaintext"].encode("utf-8"))
    sys.stdout.write(json.dumps({"ciphertext": base64.b64encode(ct).decode("ascii")}))


if __name__ == "__main__":
    main()
