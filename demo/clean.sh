#!/usr/bin/env bash
# ./platform demo clean: delete what older versions of the demos left (a
# copy of prod in namespace demo, demo branches on the in-stack Git server).
# ./platform also tears hello-world down (demo/hello-world/run.sh clean, on
# the host). Today's demos run on the real environments and leave nothing.
# Runs in the toolbox.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/lib.sh"
delete_old_copy
clean_branches
