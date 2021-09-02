#!/usr/bin/env bash
source $HOME/.bashrc
source $HOME/.rvm/scripts/rvm
rvm use .
type rvm | head -1
bundle exec localpodbinary printenv


