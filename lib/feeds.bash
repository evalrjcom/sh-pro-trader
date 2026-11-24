venues=(coinbase kraken bitstamp)

# A failed request leaves the previous validated chart in place.
fetch() {
    local venue=$1 output=$2 error=$3 url filter pair seconds result
    local payload=$output.json pending=$output.new allow_missing_volume=false
    case $venue in
        yahoo)
            pair=${symbol//^/%5E}
            url="https://query1.finance.yahoo.com/v8/finance/chart/$pair?interval=$interval&range=$range"
            allow_missing_volume=true
            # shellcheck disable=SC2016 # These variables belong to jq.
            filter='.chart | select(.error == null) | .result[0] as $r |
                $r.indicators.quote[0] as $q |
                [$r.timestamp | keys[] as $i | [ .[$i], $q.open[$i], $q.high[$i],
                 $q.low[$i], $q.close[$i], $q.volume[$i] ]]' ;;
        coinbase)
            seconds=$((minutes * 60))
            url="https://api.exchange.coinbase.com/products/$symbol/candles?granularity=$seconds"
            filter='map([.[0], .[3], .[2], .[1], .[4], .[5]])' ;;
        kraken)
            pair=${symbol/-/}
            url="https://api.kraken.com/0/public/OHLC?pair=$pair&interval=$minutes"
            filter='select(.error == []) | .result | del(.last) | to_entries |
                select(length == 1) | .[0].value |
                map([.[0], .[1], .[2], .[3], .[4], .[6]])' ;;
        bitstamp)
            pair=$(printf '%s' "${symbol/-/}" | tr '[:upper:]' '[:lower:]')
            seconds=$((minutes * 60))
            url="https://www.bitstamp.net/api/v2/ohlc/$pair/?step=$seconds&limit=300"
            filter='.data.ohlc | map([.timestamp, .open, .high, .low, .close, .volume])' ;;
        *) printf 'unknown exchange\n' > "$error"; return 1 ;;
    esac

    # Ignore per-user curl defaults so the endpoint, output and timing stay predictable.
    if ! result=$(curl -q --fail --silent --show-error --compressed --connect-timeout 4 \
        --max-time 10 --user-agent 'sh-pro-trader/1.0' --output "$payload" \
        --write-out '%{http_code} %{time_total}' "$url" 2>"$error"); then
        return 1
    fi
    if [[ ! $result =~ ^2[0-9]{2}\ ([0-9]+\.[0-9]+)$ ]]; then
        printf 'unexpected HTTP status or timing\n' > "$error"
        return 1
    fi
    local elapsed=${BASH_REMATCH[1]}

    # Validate exactly one document before publishing any rows. The numeric bound
    # leaves room for the renderer's range, volume and moving-average arithmetic.
    # Yahoo can provide OHLC for an index without reporting its trading volume.
    if ! jq -esr --argjson allow_missing_volume "$allow_missing_volume" '
        def number: try tonumber catch null;
        def valid_number: type == "number" and (isnan | not) and . >= -1e300 and . <= 1e300;
        select(length == 1) | .[0] | '"$filter"' |
        map(.[0:5] as $ohlc |
            ($ohlc | map(number)) +
            [if .[5] == null and $allow_missing_volume then "-" else (.[5] | number) end]) |
        map(select((.[0:5] | all(.[]; valid_number)) and
            .[0] > 0 and .[0] <= 253402300799 and (.[0] | floor) == .[0] and
            .[2] >= .[1] and .[2] >= .[4] and .[3] <= .[1] and .[3] <= .[4] and
            (.[5] == "-" or (.[5] | valid_number and . >= 0)))) |
        map(.[0] |= floor) | unique_by(.[0]) | .[-300:][] | @tsv' "$payload" > "$pending" 2>"$error"; then
        printf 'empty or invalid candle response\n' > "$error"
        return 1
    fi
    if ! mv -- "$pending" "$output" 2>"$error"; then
        return 1
    fi
    printf '%s\n' "$elapsed"
}

benchmark() {
    local samples=$1 round venue pid
    local -a pids
    for venue in "${venues[@]}"; do : > "$tmp/$venue.times" || return 1; done
    for ((round=1; round<=samples; round++)); do
        pids=()
        for venue in "${venues[@]}"; do
            (
                if fetch "$venue" "$tmp/$venue.candles" "$tmp/$venue.error" >> "$tmp/$venue.times"; then
                    date -u '+%H:%M:%S UTC' > "$tmp/$venue.fetched"
                fi
            ) &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" || :; done
    done
    # Retain zero-success venues for diagnostics. A majority ranks ahead of
    # partial success, then median latency ranks each group.
    for venue in "${venues[@]}"; do
        sort -n "$tmp/$venue.times" | awk -v venue="$venue" -v samples="$samples" '
            { times[NR]=$1 }
            END {
                if (NR) {
                    middle=int((NR+1)/2)
                    median=NR%2 ? times[middle] : (times[middle]+times[middle+1])/2
                    printf "%.6f %d %s %d\n", median, NR <= samples/2, venue, NR
                } else {
                    printf "0 2 %s 0\n", venue
                }
            }'
    done | sort -k2,2n -k1,1n -k3,3 > "$tmp/ranked"
}
