#!/bin/bash
# Script to split log files by log level
# Usage: ./split_logs_by_level.sh <experiment_dir>
#
# Creates per-host directories with: error.log, warn.log, info.log, debug.log, trace.log, other.log

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
EXPERIMENT_DIR=""

if [ -z "$1" ]; then
    echo "Usage: $0 <experiment_dir>"
    echo "Example: $0 experiments/themis-lego-bft/minimal_4rep_test"
    exit 1
fi

EXPERIMENT_DIR="$1"

# Find hosts directory
if [ -d "$EXPERIMENT_DIR/hosts" ]; then
    HOSTS_DIR="$EXPERIMENT_DIR/hosts"
elif [ -d "$EXPERIMENT_DIR" ]; then
    HOSTS_DIR="$EXPERIMENT_DIR"
else
    echo "Error: Cannot find hosts directory in '$EXPERIMENT_DIR'"
    exit 1
fi

# Output directory
OUTPUT_BASE="$EXPERIMENT_DIR/analysis/split_logs"
mkdir -p "$OUTPUT_BASE"

echo "=== LOG LEVEL SPLITTER ==="
echo "Experiment: $EXPERIMENT_DIR"
echo "Output: $OUTPUT_BASE"
echo ""

# Function to split a single log file
split_log_file() {
    local log_file="$1"
    local output_dir="$2"
    
    mkdir -p "$output_dir"
    
    # Create a temporary file with ANSI codes stripped
    local stripped_file
    stripped_file=$(mktemp)
    trap "rm -f '$stripped_file'" RETURN
    
    sed 's/\x1b\[[0-9;]*m//g' "$log_file" > "$stripped_file"
    
    # Extract logs by level (only ERROR, WARN, INFO - skip DEBUG/TRACE due to volume)
    grep " ERROR " "$stripped_file" > "$output_dir/error.log" 2>/dev/null || true
    grep " WARN " "$stripped_file" > "$output_dir/warn.log" 2>/dev/null || true
    grep " INFO " "$stripped_file" > "$output_dir/info.log" 2>/dev/null || true
    # Only non-log lines (multi-line configs, stack traces) - exclude DEBUG/TRACE
    grep -v -e " ERROR " -e " WARN " -e " INFO " -e " DEBUG " -e " TRACE " "$stripped_file" > "$output_dir/other.log" 2>/dev/null || true
    
    rm -f "$stripped_file"
}

# Process all hosts
for host_dir in "$HOSTS_DIR"/themis*; do
    if [ -d "$host_dir" ]; then
        host_name=$(basename "$host_dir")
        stdout_file=$(ls "$host_dir"/*.stdout 2>/dev/null | head -n 1)
        
        if [ -f "$stdout_file" ]; then
            output_dir="$OUTPUT_BASE/$host_name"
            echo -n "Processing $host_name... "
            
            split_log_file "$stdout_file" "$output_dir"
            
            # Count lines per level
            error_count=$(wc -l < "$output_dir/error.log" 2>/dev/null || echo "0")
            warn_count=$(wc -l < "$output_dir/warn.log" 2>/dev/null || echo "0")
            info_count=$(wc -l < "$output_dir/info.log" 2>/dev/null || echo "0")
            
            echo "E:$error_count W:$warn_count I:$info_count"
        fi
    fi
done

echo ""
echo "Done! Split logs saved to: $OUTPUT_BASE"
