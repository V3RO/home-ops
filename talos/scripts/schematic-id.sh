#!/usr/bin/env bash
# Looks up the Talos Image Factory schematic ID for image/schematic.yaml
# and prints it on stdout. Read-only network call to the public factory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FACTORY_URL="${FACTORY_URL:-https://factory.talos.dev}"
SCHEMATIC_FILE="${ROOT_DIR}/image/schematic.yaml"

curl -sSL -X POST --data-binary @"${SCHEMATIC_FILE}" "${FACTORY_URL}/schematics" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])'
