#!/usr/bin/env bash
# PBRP build environment for rodin.
# Sourced by build/envsetup.sh; keep it side-effect free.

export ALLOW_MISSING_DEPENDENCIES=true
export LC_ALL=C

# Only matters on the older envsetup; harmless on newer trees.
add_lunch_combo pb_rodin-eng 2>/dev/null || true
