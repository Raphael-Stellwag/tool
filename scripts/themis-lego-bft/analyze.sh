#!/bin/bash

# Master Analysis Script for Themis experiments
# Runs all analysis tools and generates a comprehensive report.
#
# Usage: ./analyze.sh <experiment_dir>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 <experiment_dir>"
    echo "Example: $0 experiments/themis-lego-bft/minimal_4rep_test"
    exit 1
fi

EXPERIMENT_DIR="$1"

if [ ! -d "$EXPERIMENT_DIR" ]; then
    echo "Error: Directory '$EXPERIMENT_DIR' does not exist"
    exit 1
fi

ANALYSIS_DIR="$EXPERIMENT_DIR/analysis"
mkdir -p "$ANALYSIS_DIR"

echo "========================================"
echo "  THEMIS EXPERIMENT ANALYSIS"
echo "========================================"
echo ""
echo "Experiment: $EXPERIMENT_DIR"
echo "Output: $ANALYSIS_DIR"
echo ""

# Track start time
START_TIME=$(date +%s)

# --- 1. Log Analysis ---
echo "[1/3] Running log analysis..."
if "$SCRIPT_DIR/analyze_logs.sh" "$EXPERIMENT_DIR" > /dev/null 2>&1; then
    echo "      ✓ Saved to: $ANALYSIS_DIR/logs_analysis.txt"
else
    echo "      ✗ Log analysis failed"
fi

# --- 2. Split Logs ---
echo "[2/3] Splitting logs by level..."
if "$SCRIPT_DIR/split_logs_by_level.sh" "$EXPERIMENT_DIR" > /dev/null 2>&1; then
    echo "      ✓ Saved to: $ANALYSIS_DIR/split_logs/"
else
    echo "      ✗ Log splitting failed"
fi

# --- 3. PCAP Analysis ---
echo "[3/3] Running PCAP analysis..."
if command -v tcpdump >/dev/null 2>&1; then
    if "$SCRIPT_DIR/analyze_pcaps.sh" "$EXPERIMENT_DIR" > /dev/null 2>&1; then
        echo "      ✓ Saved to: $ANALYSIS_DIR/pcap_analysis.txt"
        echo "      ✓ CSV data: $ANALYSIS_DIR/pcap_data/"
    else
        echo "      ✗ PCAP analysis failed"
    fi
else
    echo "      ⚠ Skipped (tcpdump not available)"
fi

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "========================================"
echo "  ANALYSIS COMPLETE"
echo "========================================"
echo ""
echo "Duration: ${DURATION}s"
echo "Output directory: $ANALYSIS_DIR"
echo ""
echo "Generated files:"
ls -la "$ANALYSIS_DIR" 2>/dev/null | grep -v "^total" | grep -v "^d" | awk '{print "  - " $NF " (" $5 " bytes)"}' || true
echo ""

# Generate summary file
SUMMARY_FILE="$ANALYSIS_DIR/summary.txt"
{
    echo "Themis Experiment Analysis Summary"
    echo "=================================="
    echo ""
    echo "Experiment: $EXPERIMENT_DIR"
    echo "Analyzed at: $(date)"
    echo "Duration: ${DURATION}s"
    echo ""
    echo "Generated Files:"
    echo "----------------"
    
    if [ -f "$ANALYSIS_DIR/logs_analysis.txt" ]; then
        echo "✓ logs_analysis.txt - Protocol performance metrics"
    fi
    
    if [ -d "$ANALYSIS_DIR/split_logs" ]; then
        host_count=$(ls -d "$ANALYSIS_DIR/split_logs"/*/ 2>/dev/null | wc -l)
        echo "✓ split_logs/ - Logs split by level ($host_count hosts)"
    fi
    
    if [ -f "$ANALYSIS_DIR/pcap_analysis.txt" ]; then
        echo "✓ pcap_analysis.txt - Network statistics"
    fi
    
    if [ -d "$ANALYSIS_DIR/pcap_data" ]; then
        csv_count=$(ls "$ANALYSIS_DIR/pcap_data"/*.csv 2>/dev/null | wc -l)
        echo "✓ pcap_data/ - Traffic CSVs and plots ($csv_count files)"
    fi
    
    echo ""
    echo "Quick Stats (from logs_analysis.txt):"
    echo "--------------------------------------"
    if [ -f "$ANALYSIS_DIR/logs_analysis.txt" ]; then
        grep -E "^(Host:|Batching|RBC|PBFT|themis)" "$ANALYSIS_DIR/logs_analysis.txt" 2>/dev/null | head -20
    fi
} > "$SUMMARY_FILE"

echo "Summary saved to: $SUMMARY_FILE"
