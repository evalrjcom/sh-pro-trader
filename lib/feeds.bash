venues=(coinbase kraken bitstamp)

# Write time_total to stdout and normalized ascending t/o/h/l/c/v rows to the chart file.
fetch() {
    local venue=$1 output=$2 url filter pair seconds stamp
    local payload=$output.json
    local error=${3:-$tmp/error}
    case $venue in
        yahoo)
            pair=${symbol//^/%5E}
            url="https://query1.finance.yahoo.com/v8/finance/chart/$pair?interval=$interval&range=$range"
            filter='.chart.result[0] | .indicators.quote[0] as $q |
                [.timestamp | keys[] as $i | [ .[$i], $q.open[$i], $q.high[$i],
                 $q.low[$i], $q.close[$i], $q.volume[$i] ]]' ;;
        coinbase)
            seconds=$((minutes * 60))
            url="https://api.exchange.coinbase.com/products/$symbol/candles?granularity=$seconds"
            filter='map([.[0], .[3], .[2], .[1], .[4], .[5]])' ;;
        kraken)
            pair=${symbol/-/}
            url="https://api.kraken.com/0/public/OHLC?pair=$pair&interval=$minutes"
            filter='select(.error == []) | .result | del(.last) | to_entries[0].value |
                map([.[0], .[1], .[2], .[3], .[4], .[6]])' ;;
        bitstamp)
            pair=$(printf '%s' "${symbol/-/}" | tr '[:upper:]' '[:lower:]')
            seconds=$((minutes * 60))
            url="https://www.bitstamp.net/api/v2/ohlc/$pair/?step=$seconds&limit=300"
            filter='.data.ohlc | map([.timestamp, .open, .high, .low, .close, .volume])' ;;
    esac
    if ! stamp=$(curl --fail --silent --show-error --compressed --connect-timeout 4 \
        --max-time 10 --user-agent 'sh-pro-trader/1.0' --output "$payload" \
        --write-out '%{time_total}' "$url" 2>"$error"); then
        return 1
    fi
    if ! jq -er "$filter"' | map(map(try tonumber catch null)) |
        map(select(all(.[]; . != null) and .[0] > 0 and .[2] >= .[3] and
            .[2] >= .[1] and .[2] >= .[4] and .[3] <= .[1] and .[3] <= .[4] and .[5] >= 0)) |
        unique_by(.[0]) | .[-300:][] | @tsv' "$payload" > "$output" 2>"$error"; then
        printf 'empty or invalid candle response\n' > "$error"
        return 1
    fi
    printf '%s\n' "$stamp"
}

benchmark() {
    local samples=$1 round venue
    local -a pids
    for venue in "${venues[@]}"; do : > "$tmp/$venue"; done
    for ((round=1; round<=samples; round++)); do
        pids=()
        for venue in "${venues[@]}"; do
            fetch "$venue" "$tmp/$venue.candles" "$tmp/$venue.error" >> "$tmp/$venue" &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" || :; done
    done
    for venue in "${venues[@]}"; do
        sort -n "$tmp/$venue" | awk -v venue="$venue" -v samples="$samples" '
            { times[NR]=$1 }
            END {
                if (NR) {
                    middle=int((NR+1)/2)
                    median=NR%2 ? times[middle] : (times[middle]+times[middle+1])/2
                    printf "%.6f %d %s %d\n", median, NR <= samples/2, venue, NR
                }
            }'
    done | sort -k2,2n -k1,1n -k3,3 > "$tmp/ranked"
    [[ -s $tmp/ranked ]]
}
