#!/bin/zsh
# Puts Floo Helper in the Mac app, at Contents/Library/LoginItems: the Mac app
# comes with it, shares its sign-in with it, starts it and has it get access
# for this Mac's services (FlooHelper.swift). floo's Apps/Floo/helper.sh builds
# it, so floo has to be beside this repository. Not on iOS.
set -euo pipefail
[[ ${IS_MACCATALYST:-NO} == YES ]] || exit 0
# Working on the app itself: each of these is a build of its own, every time.
[[ ${SKIP_EMBEDS:-NO} == YES ]] && exit 0
helper=$SRCROOT/../../floo/Apps/Floo/helper.sh
if [[ ! -x $helper ]]; then
  print "error: Floo Helper is built from floo, which isn't beside this repository ($helper)"
  exit 1
fi
# helper.sh runs an xcodebuild of its own: none of this build's settings go with it.
app=$(env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh $helper)
into=$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LoginItems
mkdir -p $into
# As it is, its own signature (Floo Helper's identity) kept: TCC keys its grants to it.
rsync -a --delete $app $into/
