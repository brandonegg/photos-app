#!/usr/bin/env python3
"""Derive the generator input from Immich's OpenAPI spec (docs/DESIGN.md, D1).

The spec in api/ is never modified. This writes a patched copy next to the
generator config with two changes:
- POST /sync/stream declares its JSON Lines body, so the generated client
  exposes it as a streaming HTTPBody.
- Fields that newer Immich releases added to the responses read before
  signing in are optional, so an older server still decodes and gets the
  "older than this app" warning instead of a decoding error.

Usage: prepare-spec.py <input-spec> <output-spec>
"""

import json
import sys

# The server sends application/jsonlines+json. The generator would treat any
# "+json" type as a single JSON document, so the patch declares */* instead:
# that is generated as a raw HTTPBody and matches whatever the server sends.
SYNC_STREAM_CONTENT_TYPE = "*/*"

# schema -> fields made optional. Each was added after 3.3.5 (featureLevel and
# backups in 3.4.x); the app reads neither.
OPTIONAL_FOR_OLDER_SERVERS = {
    "ServerVersionResponseDto": ["featureLevel"],
    "ServerFeaturesDto": ["backups"],
}


def patch(spec: dict) -> dict:
    response = spec["paths"]["/sync/stream"]["post"]["responses"]["200"]
    if "content" in response:
        raise SystemExit("/sync/stream already declares content; review whether the patch is still needed")
    response["content"] = {
        SYNC_STREAM_CONTENT_TYPE: {"schema": {"type": "string", "format": "binary"}}
    }
    schemas = spec["components"]["schemas"]
    for name, fields in OPTIONAL_FOR_OLDER_SERVERS.items():
        required = schemas[name]["required"]
        for field in fields:
            if field not in required:
                raise SystemExit(f"{name}.{field} is no longer required; review OPTIONAL_FOR_OLDER_SERVERS")
            required.remove(field)
    return spec


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, destination = sys.argv[1], sys.argv[2]
    with open(source, encoding="utf-8") as f:
        spec = json.load(f)
    with open(destination, "w", encoding="utf-8") as f:
        json.dump(patch(spec), f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
