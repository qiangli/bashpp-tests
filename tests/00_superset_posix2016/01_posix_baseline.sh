#!/usr/bin/env bashy
# POSIX 1003.1-2016 (VSC-PCTS2016) Non-Regression Fixture
# Mode: bashy --posix --bashpp

set -e

# Verify standard POSIX parameter expansion, arithmetic, and pipeline semantics
x="hello world"
if [ "${x#hello }" != "world" ]; then
    echo "POSIX parameter expansion fail"
    exit 1
fi

val=$(( 10 + 20 * 2 ))
if [ "${val}" -ne 50 ]; then
    echo "POSIX arithmetic evaluation fail"
    exit 1
fi

res=$(echo "foo" | tr 'f' 'b')
if [ "${res}" != "boo" ]; then
    echo "POSIX pipeline subshell fail"
    exit 1
fi

echo "ok 1 - POSIX 1003.1-2016 superset baseline test passed"
