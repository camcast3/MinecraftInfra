#!/bin/sh
set -eu

saved=/pal/Package/Pal/Saved
chown -R --no-dereference user:usergroup "$saved"
