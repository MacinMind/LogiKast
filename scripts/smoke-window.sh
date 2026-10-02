#!/bin/bash
# Launches the built Debug app and checks each page renders (not blank) in a real window.
# Briefly shows iceKast windows on screen. Run after UI changes: scripts/smoke-window.sh
cd "$(dirname "$0")/.." && exec swift scripts/smoke_window.swift "${1:-build/xcode/Build/Products/Debug/iceKast.app}"
