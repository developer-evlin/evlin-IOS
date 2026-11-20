#!/bin/bash
# Restart onboarding on both Demo simulators, from the very start
# (Parent / Child), linked so they pair for real. Run it yourself, any time:
#
#   scripts/restart-onboarding.sh           restart with the app as installed
#   scripts/restart-onboarding.sh --build   build the Demo app first (after code changes)
#   scripts/restart-onboarding.sh family    skip onboarding: the sample family,
#                                           three children with their tasks and
#                                           habits (the iPad as Mia's device)
#   scripts/restart-onboarding.sh light     both phones in light mode
#   scripts/restart-onboarding.sh dark      both phones in dark mode
#                                           (combine: scripts/restart-onboarding.sh family dark --build)
#
# The Demo app only (com.evlin.ios.demo), never the real one. See
# scripts/demo-pair.sh for what it does.
set -euo pipefail
cd "$(dirname "$0")/.."
exec scripts/demo-pair.sh start "$@"
