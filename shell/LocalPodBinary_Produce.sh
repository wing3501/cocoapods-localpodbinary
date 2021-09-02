#!/usr/bin/env bash
source $HOME/.bashrc
source $HOME/.rvm/scripts/rvm
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
#echo "${SRCROOT}"

rvm use .
type rvm | head -1
bundle exec localpodbinary produce

