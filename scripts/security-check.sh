#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the advisory check." >&2
  exit 1
fi

echo "Fetching latest n8n GitHub security advisories..."
advisories="$(curl -fsSL --max-time 20 "https://api.github.com/repos/n8n-io/n8n/security-advisories?per_page=20")"

if printf '%s\n' "${advisories}" | grep -Eiq '"severity"[[:space:]]*:[[:space:]]*"(critical|high)"|remote code execution|RCE|sandbox escape'; then
  echo "High/critical/RCE advisory signal found. Review before delaying updates:"
  echo "https://github.com/n8n-io/n8n/security/advisories"
  exit 2
fi

echo "No high/critical/RCE advisory signal found in the latest public n8n advisories."
