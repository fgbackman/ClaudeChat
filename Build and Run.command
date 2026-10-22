#!/bin/bash
# Double-click this file in Finder to build, install and launch Claude Chat.
cd "$(dirname "$0")"
bash ./build-app.sh
status=$?
echo ""
if [ $status -ne 0 ]; then
  echo "Build failed (exit $status). The full log is in build.log next to this file."
fi
echo "You can close this window."
