#!/bin/sh
set -eu

if [ "${CONFIGURATION:-}" != "Release" ]; then
    exit 0
fi

if [ ! -d "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
    echo "error: dSYM output folder is unavailable: ${DWARF_DSYM_FOLDER_PATH:-<unset>}"
    exit 1
fi

framework_binary="${TARGET_BUILD_DIR:-}/${FRAMEWORKS_FOLDER_PATH:-Frameworks}/Sentry.framework/Sentry"
framework_dsym="${DWARF_DSYM_FOLDER_PATH}/Sentry.framework.dSYM"
artifact_root="${SENTRY_ARTIFACTS_ROOT:-${BUILD_DIR:-}/../../SourcePackages/artifacts/sentry-cocoa}"

if [ -f "$framework_binary" ] && [ ! -d "$framework_dsym" ] && [ -d "$artifact_root" ]; then
    framework_uuids=$(dwarfdump --uuid "$framework_binary" | awk '{print $2}' | sort)
    find "$artifact_root" -type d -path '*/dSYMs/Sentry.framework.dSYM' -print | while IFS= read -r candidate; do
        candidate_binary="${candidate}/Contents/Resources/DWARF/Sentry"
        [ -f "$candidate_binary" ] || continue
        candidate_uuids=$(dwarfdump --uuid "$candidate_binary" | awk '{print $2}' | sort)
        matches=1
        for framework_uuid in $framework_uuids; do
            if ! printf '%s\n' "$candidate_uuids" | grep -Fxq "$framework_uuid"; then
                matches=0
                break
            fi
        done
        if [ "$matches" -eq 1 ]; then
            ditto "$candidate" "$framework_dsym"
            echo "Copied matching Sentry.framework dSYM into archive symbols."
            break
        fi
    done
fi

if [ -f "$framework_binary" ] && [ ! -d "$framework_dsym" ]; then
    echo "warning: no matching Sentry.framework dSYM was found in the resolved Swift package artifacts."
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
    echo "warning: Sentry dSYM upload skipped; set SENTRY_AUTH_TOKEN, SENTRY_ORG, and SENTRY_PROJECT for Release builds."
    exit 0
fi

sentry_cli=$(command -v sentry-cli || true)
if [ -z "$sentry_cli" ]; then
    for candidate in /opt/homebrew/bin/sentry-cli /usr/local/bin/sentry-cli; do
        if [ -x "$candidate" ]; then
            sentry_cli=$candidate
            break
        fi
    done
fi

if [ -z "$sentry_cli" ]; then
    echo "warning: Sentry dSYM upload skipped; install sentry-cli and make it available to Xcode build scripts."
    exit 0
fi

"$sentry_cli" debug-files upload \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$DWARF_DSYM_FOLDER_PATH"