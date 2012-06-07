#!/bin/bash -l

# Disallow errors
set -e

if [[ -z $WORKSPACE ]] ; then
  # Support execution from the shell
  export PROJECT_DIR=$(pwd);
else
  export PROJECT_DIR=$WORKSPACE/nodule;
fi

cd $PROJECT_DIR

echo "Loading RVM..."
source $HOME/.rvm/scripts/rvm;
rvm use --create 1.9.2@nodule

bundle update

echo START TASK: tests
bundle exec rake test
echo END TASK
