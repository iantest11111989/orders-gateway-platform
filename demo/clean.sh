#!/usr/bin/env bash
# ./platform demo clean: delete the demo copy (namespace demo) and any demo
# branch left on the in-stack Git server. ./platform also tears hello-world
# down (demo/hello-world/run.sh clean, on the host).
# Runs in the toolbox.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/lib.sh"
delete_app
clean_branches
