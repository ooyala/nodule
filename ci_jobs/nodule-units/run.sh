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
source $HOME/.rvm/scripts/rvm || echo "couldn't load RVM script"
echo "Using Ruby 1.9.2"
rvm use --create 1.9.2-p290@nodule

echo "Starting bundle update"
bundle update

echo START TASK: tests
bundle exec rake test
echo END TASK
