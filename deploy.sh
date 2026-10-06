#!/usr/bin/env bash
# Compatibility entry: native PowerShell owns verification and filesystem changes.
set -euo pipefail
export PATH="/usr/bin:/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS="${GTP_POWERSHELL:-C:/Program Files/PowerShell/7/pwsh.exe}"
exec "$PS" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/dev.ps1" Deploy
