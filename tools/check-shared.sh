#!/bin/bash
# Checks that the source files shared between tools are still byte-for-byte identical.
# Each tool builds on its own, so shared code is copied into every tool that needs it.
# If you change one of these files, change the original and copy it to the others, then run this.
# Usage (from anywhere): tools/check-shared.sh
cd "$(dirname "$0")/.." || exit 1
status=0
check() {            # check <original> <copy> [<copy> ...]
  local original="$1"; shift
  for copy in "$@"; do
    if cmp -s "$original" "$copy"; then echo "ok       $copy"
    else echo "DIFFERS  $copy   (original: $original)"; status=1; fi
  done
}
check keyvault/Sources/VaultCrypto.swift      leakguard/Sources/VaultCrypto.swift chatkeep/Sources/VaultCrypto.swift
check keyvault/Sources/PasswordPolicy.swift   chatkeep/Sources/PasswordPolicy.swift
check keyvault/Sources/Local.swift            leakguard/Sources/Local.swift redact/Sources/Local.swift contextpack/Sources/Local.swift chatkeep/Sources/Local.swift
check leakguard/Sources/SecretRules.swift     redact/Sources/SecretRules.swift contextpack/Sources/SecretRules.swift chatkeep/Sources/SecretRules.swift
check leakguard/Sources/GitRunner.swift       contextpack/Sources/GitRunner.swift
check leakguard/Sources/SafeRead.swift        contextpack/Sources/SafeRead.swift
check leakguard/Sources/VaultReader.swift     chatkeep/Sources/VaultReader.swift
check redact/Sources/RedactionEngine.swift    chatkeep/Sources/RedactionEngine.swift
[ $status -eq 0 ] && echo "All shared files match." || echo "Some shared files differ: fix the copies, then run this again."
exit $status
