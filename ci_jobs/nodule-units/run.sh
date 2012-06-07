#!/bin/bash -l

# Disallow errors
set -e

if [[ -z $WORKSPACE ]] ; then
  # Support execution from the shell
  export PROJECT_DIR=$(pwd);
else
  export PROJECT_DIR=$WORKSPACE/glowworm;
fi

cd $PROJECT_DIR

bundle update

echo START TASK: tests
bundle exec rake test
echo END TASK
