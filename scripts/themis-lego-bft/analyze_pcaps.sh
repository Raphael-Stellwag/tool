#!/bin/bash

# Pcap Analysis Tool
# Analyzes pcap files to calculate network stats and identify TCP retransmissions.
#
# Usage: ./analyze_pcaps.sh <experiment_dir> [--limit <N>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <experiment_dir> [--limit <N>]"
    exit 1
fi

INPUT="$1"
LIMIT=""

shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --limit) LIMIT="-c $2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

P_FILES=""
CSV_DIR=""
OUTPUT_FILE=""

if [ -f "$INPUT" ]; then
    P_FILES="$INPUT"
    echo "Analyzing single file: $INPUT"
elif [ -d "$INPUT" ]; then
    if [ -d "$INPUT/hosts" ]; then
        TARGET_DIR="$INPUT/hosts"
        # Set up output directory for experiment analysis
        ANALYSIS_DIR="$INPUT/analysis"
        CSV_DIR="$ANALYSIS_DIR/pcap_data"
        OUTPUT_FILE="$ANALYSIS_DIR/pcap_analysis.txt"
        mkdir -p "$CSV_DIR"
    else
        TARGET_DIR="$INPUT"
    fi
     
    echo "Analyzing pcap files in $TARGET_DIR..."
    P_FILES=$(find "$TARGET_DIR" -name "*.pcap" | grep -v "127.0.0.1" | sort)
    
    if [ -z "$P_FILES" ]; then
        echo "No pcap files found in $TARGET_DIR"
        exit 1
    fi
else
    echo "Error: $INPUT is not a valid file or directory"
    exit 1
fi

if [ -n "$CSV_DIR" ]; then
    echo "Traffic CSVs will be saved to: $CSV_DIR"
fi

# Run the analysis
run_analysis() {
    echo "=== PCAP ANALYSIS ==="
    echo ""
    echo "---------------------------------------------------------------------------------------------------------------------------------------------------"
    printf "%-20s | %-10s | %-10s | %-8s | %-10s | %-8s | %-8s | %-8s | %-8s | %-8s\n" "Host" "Pkts" "Data(MB)" "Dur(s)" "Mbps" "Retrans" "Retr %" "Min(ms)" "Med(ms)" "Max(ms)"
    echo "---------------------------------------------------------------------------------------------------------------------------------------------------"

    # Iterate over pcap files
    echo "$P_FILES" | while read -r pcap_file; do
        [ -z "$pcap_file" ] && continue
        filename=$(basename "$pcap_file")
        host_name=$(echo "$filename" | cut -d'-' -f1)
        
        host_ip=$(echo "$filename" | sed -E 's/^.*-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.pcap$/\1/')
        if [ "$host_ip" == "$filename" ]; then host_ip=""; fi
        
        # CSV File for this host
        csv_file=""
        if [ -n "$CSV_DIR" ]; then
            csv_file="$CSV_DIR/${host_name}.csv"
            echo "Second,BytesIn,BytesOut" > "$csv_file"
        fi

        stats=$(tcpdump -nn -tt -r "$pcap_file" $LIMIT 2>/dev/null | awk -v my_ip="$host_ip" -v csv_out="$csv_file" '
        BEGIN {
            pkts = 0
            bytes = 0
            retrans = 0
            start_ts = 0
            end_ts = 0
            rtt_count = 0
        }
        
        function get_median(arr, n) {
            if (n == 0) return 0
            asort(arr, sorted)
            if (n % 2 == 1) {
                return sorted[int(n/2) + 1]
            } else {
                return (sorted[n/2] + sorted[n/2 + 1]) / 2.0
            }
        }
        
        {
            ts = $1
            if (start_ts == 0) start_ts = ts
            end_ts = ts
            
            rel_bucket = int((ts - start_ts) * 10)
            
            if ($2 == "IP") {
                src = $3
                dst = $5
                sub(/:$/, "", dst)
                
                split(src, s_parts, ".")
                src_ip = s_parts[1] "." s_parts[2] "." s_parts[3] "." s_parts[4]
                split(dst, d_parts, ".")
                dst_ip = d_parts[1] "." d_parts[2] "." d_parts[3] "." d_parts[4]
                
                pkts++
                
                len_val = 0
                for(i=6; i<=NF; i++) {
                    if($i == "length") {
                        len_str = $(i+1)
                        sub(/:$/, "", len_str)
                        sub(/,$/, "", len_str)
                        len_val = len_str + 0
                        break
                    }
                }
                bytes += len_val
                
                if (csv_out != "") {
                    is_out = 0
                    if (my_ip != "") {
                       if (src_ip == my_ip) is_out = 1
                    } else {
                       is_out = 1 
                    }
                    
                    if (is_out) {
                        bytes_out[rel_bucket] += len_val
                    } else {
                        bytes_in[rel_bucket] += len_val
                    }
                }
                
                seq_start = -1
                seq_end = -1
                for(i=6; i<=NF; i++) {
                    if($i == "seq") {
                        seq_str = $(i+1)
                        sub(/,$/, "", seq_str)
                        if (index(seq_str, ":")) {
                            split(seq_str, a, ":")
                            seq_start = a[1]
                            seq_end = a[2]
                        } else {
                            seq_start = seq_str
                            seq_end = seq_start + len_val 
                        }
                        if (seq_start == seq_end && len_val == 0) seq_end = seq_start + 1 
                        break
                    }
                }
                
                ack_val = -1
                for(i=6; i<=NF; i++) {
                    if($i == "ack") {
                        ack_str = $(i+1)
                        sub(/,$/, "", ack_str)
                        ack_val = ack_str + 0
                        break
                    }
                }
                
                flow_key = src ">" dst
                reverse_key = dst ">" src
                
                if (len_val > 0 && seq_start != -1) {
                    key = flow_key "_" seq_start
                    if (key in seen) {
                        retrans++
                    } else {
                        seen[key] = 1
                        
                        if (my_ip == "" || src_ip == my_ip) {
                            rtt_key = flow_key "_" seq_end
                            if (!(rtt_key in sent_ts)) {
                                sent_ts[rtt_key] = ts
                            }
                        }
                    }
                }
                
                if (ack_val != -1) {
                    match_key = reverse_key "_" ack_val
                    if (match_key in sent_ts) {
                        send_time = sent_ts[match_key]
                        rtt = (ts - send_time) * 1000.0
                        if (rtt >= 0) {
                            rtt_vals[++rtt_count] = rtt
                        }
                        delete sent_ts[match_key]
                    }
                }
            }
        }
        
        END {
            duration = end_ts - start_ts
            if (duration < 0) duration = 0
            
            if (csv_out != "") {
                max_bucket = int(duration * 10)
                for (b=0; b<=max_bucket; b++) {
                    bi = (b in bytes_in) ? bytes_in[b] : 0
                    bo = (b in bytes_out) ? bytes_out[b] : 0
                    time_sec = sprintf("%.1f", b / 10.0)
                    print time_sec "," bi "," bo >> csv_out
                }
            }
            
            median_rtt = get_median(rtt_vals, rtt_count)
            
            min_rtt = 0
            max_rtt = 0
            if (rtt_count > 0) {
                min_rtt = rtt_vals[1]
                max_rtt = rtt_vals[1]
                for(i=1; i<=rtt_count; i++) {
                    if(rtt_vals[i] < min_rtt) min_rtt = rtt_vals[i]
                    if(rtt_vals[i] > max_rtt) max_rtt = rtt_vals[i]
                }
            }
            
            print pkts, bytes, duration, retrans, min_rtt, median_rtt, max_rtt
        }
        ')
        
        read -r pkts bytes duration retrans min_rtt median_rtt max_rtt <<< "$stats"
        
        # Generate Plot if CSV exists and gnuplot is available
        if [ -n "$csv_file" ] && [ -f "$csv_file" ] && command -v gnuplot >/dev/null 2>&1; then
            png_file="${csv_file%.csv}.png"
            gnuplot -e "
                set terminal png size 800,600;
                set output '$png_file';
                set title 'Network Traffic - $host_name (100ms resolution)';
                set xlabel 'Time (s)';
                set ylabel 'Throughput (Mbps)';
                set datafile separator ',';
                set key outside;
                set grid;
                plot '$csv_file' using 1:(\$2*80/1000000) with lines title 'In', \
                     '$csv_file' using 1:(\$3*80/1000000) with lines title 'Out';
            " >/dev/null 2>&1
        fi
        
        mb_bytes=$(echo "$bytes" | awk '{printf "%.2f", $1 / 1048576}')
        mbps=$(echo "$bytes $duration" | awk '{if ($2 > 0) printf "%.2f", ($1 * 8) / ($2 * 1000000); else print "0.00"}')
        
        retr_pct="0.00"
        if [ "$pkts" -gt 0 ]; then
            retr_pct=$(echo "$retrans $pkts" | awk '{printf "%.2f", ($1 / $2) * 100}')
        fi
        
        printf "%-20s | %-10s | %-10s | %-8.2f | %-10s | %-8s | %-8s | %-8.2f | %-8.2f | %-8.2f\n" "$host_name" "$pkts" "$mb_bytes" "$duration" "$mbps" "$retrans" "$retr_pct" "$min_rtt" "$median_rtt" "$max_rtt"
        
    done

    echo "---------------------------------------------------------------------------------------------------------------------------------------------------"
}

# Run and optionally save to file
if [ -n "$OUTPUT_FILE" ]; then
    run_analysis | tee "$OUTPUT_FILE"
    echo ""
    echo "Analysis saved to: $OUTPUT_FILE"
else
    run_analysis
fi
