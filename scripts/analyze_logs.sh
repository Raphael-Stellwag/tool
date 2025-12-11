#!/bin/bash

# Default arguments
PROJECT="${1:-themis-lego-bft}"
TEST_SUITE="${2:-minimal_4rep_test}"
RUN_DIR="${3:-hosts}"

BASE_DIR="experiments/$PROJECT/$TEST_SUITE/$RUN_DIR"

if [ ! -d "$BASE_DIR" ]; then
    echo "Error: Directory $BASE_DIR does not exist."
    echo "Current directory: $(pwd)"
    exit 1
fi

echo "Analyzing logs in: $BASE_DIR"

# Function to calculate average
calc_avg() {
    if [ "$1" -eq 0 ]; then
        echo "0"
    else
        echo "$2 $1" | awk '{printf "%.2f", $1 / $2}'
    fi
}

# Function to calculate throughput
calc_throughput() {
    local count=$1
    local start_ts=$2
    local end_ts=$3
    
    # Check if start and end timestamps are valid numbers
    if [ -z "$start_ts" ] || [ -z "$end_ts" ]; then
        echo "0"
        return
    fi
    
    # Calculate duration in seconds
    local duration=$(echo "$end_ts $start_ts" | awk '{diff = $1 - $2; if (diff <= 0) print 0; else print diff}')
    
    if [ "$duration" == "0" ] || [ "$count" -eq 0 ]; then
        echo "0"
    else
        echo "$count $duration" | awk '{printf "%.2f", $1 / $2}'
    fi
}

# Convert ISO 8601 timestamp to seconds since epoch (with precision)
to_seconds() {
    date -d "$1" +%s.%N 2>/dev/null
}

# Temp file for intermediate data
STATS_FILE=$(mktemp)
RBC_DETAILS_FILE=$(mktemp)

# Cleanup on exit
trap "rm -f $STATS_FILE $RBC_DETAILS_FILE" EXIT
# Pre-process log file to strip ANSI codes
clean_cat() {
    sed 's/\x1b\[[0-9;]*m//g' "$1"
}

# --- REPLICA ANALYTICS ---
echo ""
echo "=== REPLICA ANALYTICS ==="
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
printf "%-15s | %-10s | %-15s | %-18s | %-15s | %-10s | %-10s | %-10s | %-10s\n" "Metric" "Count" "Avg Latency(us)" "Throughput(ops/s)" "Avg Batch Size" "Echo(us)" "Ready(us)" "Deliv(us)" "Errors"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

for host_dir in "$BASE_DIR"/themisReplica*; do
    if [ -d "$host_dir" ]; then
        host_name=$(basename "$host_dir")
        stdout_file=$(ls "$host_dir"/*.stdout 2>/dev/null | head -n 1)
        stderr_file=$(ls "$host_dir"/*.stderr 2>/dev/null | head -n 1)
        
        if [ -f "$stdout_file" ]; then
            echo "Host: $host_name"
            
            # --- Errors ---
            error_count=0
            if [ -f "$stderr_file" ]; then
                error_count=$(wc -l < "$stderr_file")
            fi
            
            # --- Batching Metrics ---
            batch_data=$(clean_cat "$stdout_file" | grep "Batch formed and flushed" | awk '{
                val = 0; size = 0;
                match($0, /formation_time_us=[0-9][0-9]*/);
                if (RSTART > 0) {
                    part = substr($0, RSTART, RLENGTH);
                    split(part, a, "=");
                    val = a[2];
                }
                match($0, /batch_size=[0-9][0-9]*/);
                if (RSTART > 0) {
                    part = substr($0, RSTART, RLENGTH);
                    split(part, b, "=");
                    size = b[2];
                }
                print $1, val, size;
            }')
            
            batch_count=$(echo "$batch_data" | grep -v "^$" | wc -l)
            
            batch_sum_latency=0
            batch_sum_size=0
            batch_start_ts=""
            batch_end_ts=""
            
            if [ "$batch_count" -gt 0 ]; then
                batch_sum_latency=$(echo "$batch_data" | awk '{sum+=$2} END {print sum}')
                batch_sum_size=$(echo "$batch_data" | awk '{sum+=$3} END {print sum}')
                batch_first_line=$(echo "$batch_data" | head -n 1)
                batch_last_line=$(echo "$batch_data" | tail -n 1)
                
                batch_start_ts=$(to_seconds $(echo "$batch_first_line" | awk '{print $1}'))
                batch_end_ts=$(to_seconds $(echo "$batch_last_line" | awk '{print $1}'))
            fi
            
            batch_avg_latency=$(calc_avg "$batch_count" "$batch_sum_latency")
            batch_avg_size=$(calc_avg "$batch_count" "$batch_sum_size")
            batch_throughput=$(calc_throughput "$batch_count" "$batch_start_ts" "$batch_end_ts")
            
            printf "%-15s | %-10s | %-15s | %-18s | %-15s | %-10s | %-10s | %-10s | %-10s\n" "Batching" "$batch_count" "$batch_avg_latency" "$batch_throughput" "$batch_avg_size" "-" "-" "-" "-"

            # --- RBC Metrics ---
            # Extract relevant log lines once
            rbc_lines=$(clean_cat "$stdout_file" | grep "RBC instance delivered")
            
            # 1. Stats Extraction
            rbc_data=$(echo "$rbc_lines" | awk '{
                val=0; size=0; echo_t=0; ready_t=0; deliv_t=0;
                match($0, /total_latency_us=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, a, "="); val = a[2]; }
                match($0, /batch_size=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, b, "="); size = b[2]; }
                match($0, /echo_phase_us=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, c, "="); echo_t = c[2]; }
                match($0, /ready_phase_us=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, d, "="); ready_t = d[2]; }
                match($0, /delivery_phase_us=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, e, "="); deliv_t = e[2]; }
                print $1, val, size, echo_t, ready_t, deliv_t;
            }')
            
            rbc_count=$(echo "$rbc_data" | grep -v "^$" | wc -l)
            rbc_avg_latency=0; rbc_throughput=0; rbc_avg_size=0; rbc_avg_echo=0; rbc_avg_ready=0; rbc_avg_deliv=0
            if [ "$rbc_count" -gt 0 ]; then
                # Calculate sums
                sums=$(echo "$rbc_data" | awk '{sl+=$2; ss+=$3; se+=$4; sr+=$5; sd+=$6} END {print sl, ss, se, sr, sd}')
                rbc_sum_latency=$(echo "$sums" | awk '{print $1}')
                rbc_sum_size=$(echo "$sums" | awk '{print $2}')
                rbc_sum_echo=$(echo "$sums" | awk '{print $3}')
                rbc_sum_ready=$(echo "$sums" | awk '{print $4}')
                rbc_sum_deliv=$(echo "$sums" | awk '{print $5}')
                
                rbc_start_ts=$(to_seconds $(echo "$rbc_data" | head -n 1 | awk '{print $1}'))
                rbc_end_ts=$(to_seconds $(echo "$rbc_data" | tail -n 1 | awk '{print $1}'))
                
                rbc_avg_latency=$(calc_avg "$rbc_count" "$rbc_sum_latency")
                rbc_avg_size=$(calc_avg "$rbc_count" "$rbc_sum_size")
                rbc_avg_echo=$(calc_avg "$rbc_count" "$rbc_sum_echo")
                rbc_avg_ready=$(calc_avg "$rbc_count" "$rbc_sum_ready")
                rbc_avg_deliv=$(calc_avg "$rbc_count" "$rbc_sum_deliv")
                rbc_throughput=$(calc_throughput "$rbc_count" "$rbc_start_ts" "$rbc_end_ts")
                
                printf "%-15s | %-10s | %-15s | %-18s | %-15s | %-10s | %-10s | %-10s | %-10s\n" "RBC (Deliver)" "$rbc_count" "$rbc_avg_latency" "$rbc_throughput" "$rbc_avg_size" "$rbc_avg_echo" "$rbc_avg_ready" "$rbc_avg_deliv" "-"
            fi

            # 2. Detailed Extract (Digest, Latency, Timestamp, BatchSize) to GLOBAL temp file
            echo "$rbc_lines" | awk -v host="$host_name" '{
                digest="UNKNOWN"
                match($0, /digest=.* batch_size=/)
                if (RSTART > 0) {
                     # Extract digest string
                     n = split($0, a, "digest=")
                     if (n >= 2) {
                         split(a[2], b, " batch_size=")
                         digest = b[1]
                         # SANITIZE DIGEST: Remove pipes to avoid delimiter collision
                         gsub(/\|/, "_", digest)
                     }
                }
                
                val=0
                match($0, /total_latency_us=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, a, "="); val = a[2]; }
                
                size=0
                match($0, /batch_size=[0-9][0-9]*/); if (RSTART > 0) { part = substr($0, RSTART, RLENGTH); split(part, b, "="); size = b[2]; }
                
                print host "|" $1 "|" val "|" digest "|" size
            }' >> "$RBC_DETAILS_FILE"

            # --- PBFT Metrics ---
            pbft_data=$(clean_cat "$stdout_file" | grep "Committed" | awk '{
                match($0, /prepare_to_commit_us=[0-9][0-9]*/);
                if (RSTART > 0) {
                    part = substr($0, RSTART, RLENGTH);
                    split(part, a, "=");
                    val = a[2];
                    print $1, val;
                }
            }')
            
            pbft_count=$(echo "$pbft_data" | grep -v "^$" | wc -l)
            if [ -z "$pbft_data" ]; then pbft_count=0; fi
            
            pbft_sum_latency=0
            pbft_start_ts=""
            pbft_end_ts=""
            
            if [ "$pbft_count" -gt 0 ]; then
                pbft_sum_latency=$(echo "$pbft_data" | awk '{sum+=$2} END {print sum}')
                pbft_first_line=$(echo "$pbft_data" | head -n 1)
                pbft_last_line=$(echo "$pbft_data" | tail -n 1)
                
                pbft_start_ts=$(to_seconds $(echo "$pbft_first_line" | awk '{print $1}'))
                pbft_end_ts=$(to_seconds $(echo "$pbft_last_line" | awk '{print $1}'))
            fi
            
            pbft_avg_latency=$(calc_avg "$pbft_count" "$pbft_sum_latency")
            pbft_throughput=$(calc_throughput "$pbft_count" "$pbft_start_ts" "$pbft_end_ts")
            
            printf "%-15s | %-10s | %-15s | %-18s | %-15s | %-10s | %-10s | %-10s | %-10s\n" "PBFT (Commit)" "$pbft_count" "$pbft_avg_latency" "$pbft_throughput" "-" "-" "-" "-" "$error_count"
            
            echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
        fi
    fi
done



# --- RBC TREND ANALYSIS ---
if [ -s "$RBC_DETAILS_FILE" ]; then
    echo ""
    echo "=== RBC TREND ANALYSIS (1s windows) ==="
    echo "----------------------------------------------------------------------------"
    printf "| %-8s | %-12s | %-12s | %-18s |\n" "Time (s)" "Instances/s" "Requests/s" "Avg Latency (us)"
    echo "----------------------------------------------------------------------------"
    
    awk -F"|" '
    BEGIN { global_min_ts = -1 }
    
    {
        ts_str = $2
        lat = $3 
        digest = $4
        size = $5
        
        # Parse timestamp to seconds (Fast manually)
        # Format: YYYY-MM-DDTHH:MM:SS.NNNNNNZ
        # Indices: 12->HH, 15->MM, 18->SS
        hh = substr(ts_str, 12, 2)
        mm = substr(ts_str, 15, 2)
        ss = substr(ts_str, 18, 2)
        
        sec_of_day = (hh * 3600) + (mm * 60) + ss
        
        # Track Global Min Timestamp across all replicas
        if (global_min_ts == -1 || sec_of_day < global_min_ts) {
            global_min_ts = sec_of_day
        }
        
        # Track per-digest stats
        # We record the FIRST time any replica delivered this instance as the "System Delivery Time"
        if (! (digest in first_ts) || sec_of_day < first_ts[digest]) {
            first_ts[digest] = sec_of_day
        }
        
        # Accumulate latency to calculate average latency for this instance across replicas
        sum_lat[digest] += lat
        cnt_lat[digest]++
        
        # Store batch size (should be same for all replicas)
        batch_size[digest] = size
    }
    
    END {
        if (global_min_ts == -1) exit;
        
        max_bucket = 0
        
        # Aggregate unique instances into buckets
        for (d in first_ts) {
            ts = first_ts[d]
            
            # Bucket relative to global start
            rel = ts - global_min_ts
            if (rel < 0) rel = 0
            bucket = int(rel)
            
            # Instance Average Latency
            inst_avg_lat = sum_lat[d] / cnt_lat[d]
            
            bucket_inst[bucket]++
            bucket_req[bucket] += batch_size[d]
            bucket_lat_sum[bucket] += inst_avg_lat
            
            if (bucket > max_bucket) max_bucket = bucket
        }
        
        # Print Table
        for (i = 0; i <= max_bucket; i++) {
             c = bucket_inst[i]
             if (c > 0) {
                 avg = bucket_lat_sum[i] / c
                 reqs = bucket_req[i]
                 printf "| %-8s | %-12s | %-12s | %-18.2f |\n", i "-" i+1, c, reqs, avg
             }
        }
    }
    ' "$RBC_DETAILS_FILE"
    echo "----------------------------------------------------------------------------"
fi

# --- DETAILED RBC ANALYSIS ---
if [ -s "$RBC_DETAILS_FILE" ]; then
    # Sort by Digest (4) and then Host (1) for clean table output
    sort -t"|" -k4,4 -k1,1 "$RBC_DETAILS_FILE" -o "$RBC_DETAILS_FILE.sorted"
    mv "$RBC_DETAILS_FILE.sorted" "$RBC_DETAILS_FILE"

    echo ""
    echo "=== RBC DETAILED ANALYSIS (Instance Latency across all replicas) ==="
    echo "--------------------------------------------------------------------------------"
    
    awk -F"|" '
    BEGIN {
        # Define formats
        fmt_head = "    | %-15s | %-30s | %-12s |\n"
        fmt_row  = "    | %-15s | %-30s | %-12s |\n"
        sep      = "    ---------------------------------------------------------------------"
    }

    {
        host = $1
        ts = $2
        lat = $3 
        digest = $4
        size = $5
        
        # Accumulate stats per digest
        sum_lat[digest] += lat
        count[digest]++
        
        # Keep one batch size (assuming approx same)
        if (size > 0) sizes[digest] = size
        
        # Store detail line
        detail_lines[digest] = detail_lines[digest] sprintf(fmt_row, host, ts, lat)
    }
    
    END {
        total_digests = 0
        global_sum_lat = 0
        
        # First pass: Calculate Averages and find Min/Max
        for (d in count) {
            avg = sum_lat[d] / count[d]
            avg_lats[d] = avg
            
            total_digests++
            global_sum_lat += avg
            
            if (total_digests == 1 || avg < min_val) {
                min_val = avg
                min_d = d
            }
            if (total_digests == 1 || avg > max_val) {
                max_val = avg
                max_d = d
            }
        }
        
        if (total_digests == 0) exit;
        
        global_avg = global_sum_lat / total_digests
        
        # Find Median/Avg Instance (Closest to Global Average)
        min_diff = -1
        mid_d = ""
        
        for (d in avg_lats) {
            diff = avg_lats[d] - global_avg
            if (diff < 0) diff = -diff
            
            if (min_diff == -1 || diff < min_diff) {
                min_diff = diff
                mid_d = d
            }
        }
        
        # --- PRINT FUNCTION ---
        print_instance("FASTEST INSTANCE", min_d, min_val)
        print_instance("SLOWEST INSTANCE", max_d, max_val)
        print_instance("AVG/MEDIAN INSTANCE", mid_d, avg_lats[mid_d])
    }
    
    function print_instance(label, d, avg) {
        printf "\n>>> %s (Digest: %s)\n", label, substr(d, 1, 30) "..." # Truncate digest
        printf "    Average Latency: %.2f us\n", avg
        printf "    Batch Size: %s\n", sizes[d]
        print sep
        printf fmt_head, "Host", "Delivery Time", "Latency (us)"
        print sep
        printf "%s", detail_lines[d]
        print sep
    }
    ' "$RBC_DETAILS_FILE"
fi

# --- NETWORK SATURATION ANALYSIS ---
# Calculate % of time each replica has at least one pending RBC from another node
echo ""
echo "=== NETWORK SATURATION ANALYSIS ==="
echo "Measures network utilization and RBC processing times."
echo "  - Recv %:       % of time with INIT in flight (proposer sent, not yet received)"
echo "  - Pending %:    % of time with pending RBC (received INIT, not yet delivered)"
echo "  - Avg Count:    Average concurrent pending RBCs when busy"
echo "  - Net Dly:      Average network delay (proposer -> receiver)"
echo "  - Process:      Average processing time (INIT received -> delivered)"
echo "--------------------------------------------------------------------------------------------"

# Create temp files for proposals, INIT received, and deliveries
PROPOSALS_FILE=$(mktemp)
INIT_RECEIVED_FILE=$(mktemp)
DELIVERIES_FILE=$(mktemp)

# Collect all proposals (proposer_id, timestamp, digest)
for host_dir in "$BASE_DIR"/themisReplica*; do
    if [ -d "$host_dir" ]; then
        stdout_file=$(ls "$host_dir"/*.stdout 2>/dev/null | head -n 1)
        if [ -f "$stdout_file" ]; then
            clean_cat "$stdout_file" | grep "RBC instance proposed" | awk '{
                # Extract replica_id
                match($0, /replica_id=[0-9]+/)
                rid = substr($0, RSTART+11, RLENGTH-11)
                
                # Extract digest (sanitize pipes)
                match($0, /digest=.* batch_size=/)
                if (RSTART > 0) {
                    n = split($0, a, "digest=")
                    if (n >= 2) {
                        split(a[2], b, " batch_size=")
                        digest = b[1]
                        gsub(/\|/, "_", digest)
                    }
                }
                
                # Timestamp is $1
                print rid "|" $1 "|" digest
            }' >> "$PROPOSALS_FILE"
        fi
    fi
done

# Collect all INIT received events (receiver_id, timestamp, digest)
# This tells us when each replica learned about an RBC from another node
for host_dir in "$BASE_DIR"/themisReplica*; do
    if [ -d "$host_dir" ]; then
        stdout_file=$(ls "$host_dir"/*.stdout 2>/dev/null | head -n 1)
        if [ -f "$stdout_file" ]; then
            clean_cat "$stdout_file" | grep "RBC INIT received" | awk '{
                # Extract receiver_id
                match($0, /receiver_id=[0-9]+/)
                rid = substr($0, RSTART+12, RLENGTH-12)
                
                # Extract digest (sanitize pipes)
                match($0, /digest=.* batch_size=/)
                if (RSTART > 0) {
                    n = split($0, a, "digest=")
                    if (n >= 2) {
                        split(a[2], b, " batch_size=")
                        digest = b[1]
                        gsub(/\|/, "_", digest)
                    }
                }
                
                # Timestamp is $1
                print rid "|" $1 "|" digest
            }' >> "$INIT_RECEIVED_FILE"
        fi
    fi
done

# Collect all deliveries (receiver_id, timestamp, digest)
for host_dir in "$BASE_DIR"/themisReplica*; do
    if [ -d "$host_dir" ]; then
        host_name=$(basename "$host_dir")
        # Extract replica number from host name (e.g., themisReplica0 -> 0)
        receiver_id=$(echo "$host_name" | sed 's/themisReplica//')
        
        stdout_file=$(ls "$host_dir"/*.stdout 2>/dev/null | head -n 1)
        if [ -f "$stdout_file" ]; then
            clean_cat "$stdout_file" | grep "RBC instance delivered" | awk -v rid="$receiver_id" '{
                # Extract digest (sanitize pipes)
                match($0, /digest=.* batch_size=/)
                if (RSTART > 0) {
                    n = split($0, a, "digest=")
                    if (n >= 2) {
                        split(a[2], b, " batch_size=")
                        digest = b[1]
                        gsub(/\|/, "_", digest)
                    }
                }
                
                # Timestamp is $1
                print rid "|" $1 "|" digest
            }' >> "$DELIVERIES_FILE"
        fi
    fi
done

# Now calculate saturation for each replica
printf "| %-15s | %-10s | %-10s | %-10s | %-12s | %-12s |\n" "Replica" "Recv %" "Pending %" "Avg Count" "Net Dly (ms)" "Process (ms)"
echo "--------------------------------------------------------------------------------------------"

awk -F"|" -v PROPOSALS="$PROPOSALS_FILE" -v INIT_RECEIVED="$INIT_RECEIVED_FILE" '
function ts_to_ms(ts) {
    # Parse YYYY-MM-DDTHH:MM:SS.NNNNNNZ -> milliseconds of day
    hh = substr(ts, 12, 2)
    mm = substr(ts, 15, 2)
    ss = substr(ts, 18, 2)
    # Get microseconds part (after the dot, before Z)
    us_part = substr(ts, 21, 6)
    if (us_part == "") us_part = 0
    
    ms = (hh * 3600000) + (mm * 60000) + (ss * 1000) + int(us_part / 1000)
    return ms
}

BEGIN {
    # Read proposals first (to calculate network delay)
    # Format: proposer_id|timestamp|digest
    while ((getline < PROPOSALS) > 0) {
        proposer = $1
        ts = $2
        digest = $3
        
        ts_ms = ts_to_ms(ts)
        
        # Store proposal time for each digest (earliest if duplicates)
        if (!(digest in proposal_time) || ts_ms < proposal_time[digest]) {
            proposal_time[digest] = ts_ms
        }
        
        # Track global time range
        if (global_min_ts == 0 || ts_ms < global_min_ts) global_min_ts = ts_ms
        if (ts_ms > global_max_ts) global_max_ts = ts_ms
    }
    close(PROPOSALS)
    
    # Read INIT received events
    # Format: receiver_id|timestamp|digest
    while ((getline < INIT_RECEIVED) > 0) {
        receiver = $1
        ts = $2
        digest = $3
        
        ts_ms = ts_to_ms(ts)
        
        # Store INIT receive time for this receiver and digest
        key = receiver "|" digest
        if (!(key in init_recv_time) || ts_ms < init_recv_time[key]) {
            init_recv_time[key] = ts_ms
        }
        
        # Track receivers
        receivers[receiver] = 1
        
        # Track global time range
        if (global_min_ts == 0 || ts_ms < global_min_ts) global_min_ts = ts_ms
        if (ts_ms > global_max_ts) global_max_ts = ts_ms
    }
    close(INIT_RECEIVED)
}

{
    # Main input is deliveries
    # Format: receiver_id|timestamp|digest
    receiver = $1
    ts = $2
    digest = $3
    
    ts_ms = ts_to_ms(ts)
    
    # Store delivery time for this receiver and digest
    key = receiver "|" digest
    if (!(key in delivery_time) || ts_ms < delivery_time[key]) {
        delivery_time[key] = ts_ms
    }
    
    # Track receivers
    receivers[receiver] = 1
    
    # Update global time range
    if (ts_ms > global_max_ts) global_max_ts = ts_ms
}

END {
    total_duration = global_max_ts - global_min_ts
    if (total_duration <= 0) {
        print "Insufficient data for saturation analysis"
        exit
    }
    
    # For each receiver, calculate metrics
    for (r in receivers) {
        # Arrays for pending and receiving events
        delete pending_events
        delete recv_events
        pending_event_count = 0
        recv_event_count = 0
        
        net_delay_sum = 0
        net_delay_count = 0
        pending_dur_sum = 0
        pending_dur_count = 0
        
        # For each INIT received by this replica
        for (key in init_recv_time) {
            split(key, parts, "|")
            recv = parts[1]
            digest = parts[2]
            
            if (recv != r) continue
            
            init_ts = init_recv_time[key]
            
            # Calculate network delay and receiving events (proposal -> INIT received)
            if (digest in proposal_time) {
                prop_ts = proposal_time[digest]
                delay = init_ts - prop_ts
                if (delay >= 0) {
                    net_delay_sum += delay
                    net_delay_count++
                    
                    # Add receiving events (+1 at proposal, -1 at INIT received)
                    recv_events[recv_event_count++] = prop_ts "|+1"
                    recv_events[recv_event_count++] = init_ts "|-1"
                }
            }
            
            # Check if this replica delivered this instance
            if (key in delivery_time) {
                deliv_ts = delivery_time[key]
                
                # Calculate pending duration (INIT received -> delivered)
                pend_dur = deliv_ts - init_ts
                if (pend_dur >= 0) {
                    pending_dur_sum += pend_dur
                    pending_dur_count++
                }
                
                # Add pending events (+1 at INIT received, -1 at delivered)
                pending_events[pending_event_count++] = init_ts "|+1"
                pending_events[pending_event_count++] = deliv_ts "|-1"
            }
        }
        
        # Calculate Receiving % (time with receiving > 0)
        # Sort receiving events
        for (i = 0; i < recv_event_count - 1; i++) {
            for (j = i + 1; j < recv_event_count; j++) {
                split(recv_events[i], ei, "|")
                split(recv_events[j], ej, "|")
                if (ei[1] > ej[1]) {
                    tmp = recv_events[i]
                    recv_events[i] = recv_events[j]
                    recv_events[j] = tmp
                }
            }
        }
        
        receiving = 0
        receiving_time = 0
        last_ts = global_min_ts
        
        for (i = 0; i < recv_event_count; i++) {
            split(recv_events[i], e, "|")
            ev_ts = e[1]
            delta = e[2]
            
            if (receiving > 0) {
                receiving_time += (ev_ts - last_ts)
            }
            
            if (delta == "+1") receiving++
            else receiving--
            
            last_ts = ev_ts
        }
        
        if (receiving > 0 && last_ts < global_max_ts) {
            receiving_time += (global_max_ts - last_ts)
        }
        
        recv_pct = (receiving_time / total_duration) * 100
        
        # Calculate Pending % (time with pending > 0)
        # Sort pending events
        for (i = 0; i < pending_event_count - 1; i++) {
            for (j = i + 1; j < pending_event_count; j++) {
                split(pending_events[i], ei, "|")
                split(pending_events[j], ej, "|")
                if (ei[1] > ej[1]) {
                    tmp = pending_events[i]
                    pending_events[i] = pending_events[j]
                    pending_events[j] = tmp
                }
            }
        }
        
        pending = 0
        pending_time = 0
        pending_sum = 0
        sample_count = 0
        last_ts = global_min_ts
        
        for (i = 0; i < pending_event_count; i++) {
            split(pending_events[i], e, "|")
            ev_ts = e[1]
            delta = e[2]
            
            if (pending > 0) {
                duration = ev_ts - last_ts
                pending_time += duration
                pending_sum += pending * duration
                sample_count += duration
            }
            
            if (delta == "+1") pending++
            else pending--
            
            last_ts = ev_ts
        }
        
        if (pending > 0 && last_ts < global_max_ts) {
            pending_time += (global_max_ts - last_ts)
            pending_sum += pending * (global_max_ts - last_ts)
            sample_count += (global_max_ts - last_ts)
        }
        
        pend_pct = (pending_time / total_duration) * 100
        avg_pending = (sample_count > 0) ? pending_sum / sample_count : 0
        avg_net_delay = (net_delay_count > 0) ? net_delay_sum / net_delay_count : 0
        avg_pend_dur = (pending_dur_count > 0) ? pending_dur_sum / pending_dur_count : 0
        
        printf "| themisReplica%-2s | %8.2f%% | %8.2f%% | %8.2f | %10.2f | %10.2f |\n", r, recv_pct, pend_pct, avg_pending, avg_net_delay, avg_pend_dur
    }
}
' "$DELIVERIES_FILE"

echo "--------------------------------------------------------------------------------------------"

# Cleanup temp files
rm -f "$PROPOSALS_FILE" "$INIT_RECEIVED_FILE" "$DELIVERIES_FILE"

# --- CLIENT ANALYTICS ---
echo ""
echo "=== CLIENT ANALYTICS ==="
echo "---------------------------------------------------------------------------------"
printf "%-15s | %-10s | %-18s\n" "Host" "Count" "Throughput(resp/s)"
echo "---------------------------------------------------------------------------------"

for host_dir in "$BASE_DIR"/themisClient*; do
    if [ -d "$host_dir" ]; then
        host_name=$(basename "$host_dir")
        stdout_file=$(ls "$host_dir"/*.stdout 2>/dev/null | head -n 1)
        
        if [ -f "$stdout_file" ]; then
             # Keyword: response. sequence=
             
             client_data=$(clean_cat "$stdout_file" | grep "response. sequence=" | awk '{
                 # We just need the timestamp for now to calc throughput
                 print $1;
             }')
             
             client_count=$(echo "$client_data" | grep -v "^$" | wc -l)
             
             client_start_ts=""
             client_end_ts=""
             
             if [ "$client_count" -gt 0 ]; then
                 client_first_line=$(echo "$client_data" | head -n 1)
                 client_last_line=$(echo "$client_data" | tail -n 1)
                 
                 client_start_ts=$(to_seconds "$client_first_line")
                 client_end_ts=$(to_seconds "$client_last_line")
             fi
             
             client_throughput=$(calc_throughput "$client_count" "$client_start_ts" "$client_end_ts")
             
             printf "%-15s | %-10s | %-18s\n" "$host_name" "$client_count" "$client_throughput"
        fi
    fi
done
echo "---------------------------------------------------------------------------------"
