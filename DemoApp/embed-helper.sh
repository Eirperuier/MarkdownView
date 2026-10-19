#!/bin/zsh
# Puts Floo Helper in the Mac app, at Contents/Library/LoginItems: the demo
# starts it, signs it in and asks it to get access for this Mac's services
# (FlooHelper.swift). floo's Apps/Floo/helper.sh builds it, so floo has to be
# beside this repository; without it the app goes without the Helper. Not on iOS.
set -euo pipefail
[[ ${IS_MACCATALYST:-NO} == YES ]] || exit 0
helper=$SRCROOT/../../floo/Apps/Floo/helper.sh
if [[ ! -x $helper ]]; then
  print "warning: no floo beside this repository ($helper): the app goes without Floo Helper"
  exit 0
fi
# helper.sh runs an xcodebuild of its own: none of this build's settings go with it.
app=$(env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh $helper)
into=$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LoginItems
mkdir -p $into
# As it is, its own signature (Floo Helper's identity) kept: TCC keys its grants to it.
rsync -a --delete $app $into/
