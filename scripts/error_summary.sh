#!/usr/bin/env bash
# Prints the unique compiler errors and test failures from the given logs, so a single
# read of the CI output shows every problem at once.
for log in "$@"; do
    [ -f "$log" ] || continue
    echo "=== $log ==="
    grep -E "error:|fatal error|Test Case .* failed|XCTAssert|Testing failed|\*\* (BUILD|TEST|ARCHIVE) FAILED" "$log" |
        sed 's/^[[:space:]]*//' | sort -u | head -150
done
exit 0
