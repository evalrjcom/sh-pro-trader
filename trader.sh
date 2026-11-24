#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C TZ=UTC0

# Market-data feeds and exchange benchmark.
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

# Embed the awk program so the script can run without a source directory.
render_chart() {
    local program
    # A NUL-delimited read reaches EOF after capturing the entire literal here-document.
    IFS= read -r -d '' program <<'TRADER_AWK' || :
BEGIN {
    status=ENVIRON["TRADER_CHART_STATUS"]
    if (color) {
        up="\033[38;5;43m"
        down="\033[38;5;203m"
        average="\033[38;5;221m"
        muted="\033[38;5;245m"
        reset="\033[0m"
    }
}
{
    timestamp[NR]=$1
    open[NR]=$2
    high[NR]=$3
    low[NR]=$4
    closing[NR]=$5
    vol[NR]=$6
    # Sum the actual window to avoid cancellation from much older prices.
    if (NR>=20) {
        total=0
        for (i=NR-19; i<=NR; i++) total+=closing[i]
        ma[NR]=total/20
    }
}
function level(price) {
    return int((ceiling-price)/(ceiling-floor)*(height-1)+0.5)
}
function clocklabel(n, format) {
    format=interval=="1d" ? "%Y-%m-%d" : "%m-%d %H:%M"
    return strftime(format,timestamp[n])
}
function axis(price, label) {
    label=sprintf("%.8g",price)
    if (length(label)>14) label=sprintf("%.7g",price)
    return sprintf("%14s",label)
}
END {
    if (NR==0) exit 1
    if (cols<34 || rows<12) {
        printf "%.*s\n",cols-1,"Resize terminal to 34x12."
        exit
    }
    # Leave a spare column so drawing the final cell cannot wrap the frame.
    cols--
    last=NR-offset
    if (last<1) last=1
    count=bars
    if (count>cols-16) count=cols-16
    if (count>last) count=last
    first=last-count+1
    height=rows-8
    if (height>32) height=32
    ceiling=high[first]
    floor=low[first]
    for (n=first; n<=last; n++) {
        if (high[n]>ceiling) ceiling=high[n]
        if (low[n]<floor) floor=low[n]
        if (sma && (n in ma)) {
            if (ma[n]>ceiling) ceiling=ma[n]
            if (ma[n]<floor) floor=ma[n]
        }
        if (vol[n]!="-") {
            volume_known++
            if (vol[n]+0>maxvol) maxvol=vol[n]+0
        }
    }
    margin=(ceiling-floor)*0.05
    if (!margin) margin=(ceiling<0 ? -ceiling : ceiling)*0.001+0.00000001
    ceiling+=margin
    floor-=margin
    change=last>1 ? closing[last]-closing[last-1] : 0
    direction=change<0 ? down : up
    title=sprintf("%s  %s  %s  %.8g",symbol,interval,exchange,closing[last])
    printf "%s%.*s%s\n",direction,cols,title,reset
    details=sprintf("O %.8g  H %.8g  L %.8g  C %.8g",open[last],high[last],low[last],closing[last])
    if (last>1 && closing[last-1]!=0) details=details sprintf("  %+.2f%%",100*change/closing[last-1])
    printf "%.*s\n",cols,details
    details=status (offset ? " | History" : " | Latest") (sma ? " | SMA 20" : "")
    # Truncate status to the terminal width.
    printf "%.*s\n",cols,details
    for (n=first; n<=last; n++) {
        top[n]=level(high[n]); bottom[n]=level(low[n])
        a=level(open[n]); b=level(closing[n])
        bodytop[n]=a<b ? a : b
        bodybottom[n]=a>b ? a : b
        ink[n]=closing[n]>=open[n] ? up : down
        if (sma && (n in ma)) maline[n]=level(ma[n])
    }
    tick=int((height-1)/4)
    if (tick<1) tick=1
    for (r=0; r<height; r++) {
        grid=r%tick==0 || r==height-1
        printf "%s%s %s%s",muted,grid ? axis(ceiling-r*(ceiling-floor)/(height-1)) : sprintf("%14s",""), grid ? "+" : "|",reset
        for (n=first; n<=last; n++) {
            if (r>=bodytop[n] && r<=bodybottom[n])
                printf "%s%s%s",ink[n],(closing[n]>=open[n] ? "█" : "▓"),reset
            else if (r>=top[n] && r<=bottom[n]) printf "%s│%s",ink[n],reset
            else if ((n in maline) && r==maline[n]) printf "%s•%s",average,reset
            else printf "%s%s%s",muted,grid ? "┄" : " ",reset
        }
        printf "\n"
    }
    if (volume) {
        # Unknown volume gets a marker instead of being shown as zero.
        printf "%14s  ",volume_known ? "Volume" : "Volume n/a"
        split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █",blocks," ")
        for (n=first; n<=last; n++) {
            v=maxvol && vol[n]+0>0 ? int(7*vol[n]/maxvol)+1 : 0
            printf "%s%s%s",ink[n],vol[n]=="-" ? "?" : (v ? blocks[v] : " "),reset
        }
        printf "\n"
    }
    left=clocklabel(first); right=clocklabel(last)
    if (count>=length(left)+length(right)+1)
        printf "%16s%s%*s%s\n","",left,count-length(left)-length(right),"",right
    else
        printf "%16s%s\n","",right
    printf "%16s%s\n","","UTC"
}
TRADER_AWK
    # Pass status as data so awk does not interpret backslash escapes in errors.
    TRADER_CHART_STATUS="$status" awk -v cols="$cols" -v rows="$rows" \
        -v bars="$bars" -v offset="$offset" -v sma="$sma" -v volume="$volume" \
        -v color="$color" -v symbol="$symbol" -v interval="$interval" -v exchange="$exchange" \
        "$program" "$tmp/chart"
}

usage() {
    cat <<'HELP'
Usage:
  ./trader.sh stock SYMBOL [INTERVAL] [--once]
  ./trader.sh crypto BASE-QUOTE [INTERVAL] [EXCHANGE|auto] [--once]
  ./trader.sh benchmark [BASE-QUOTE] [INTERVAL]

Stock intervals: 1m 5m 15m 1h 1d (default 1d)
Crypto intervals: 1m 5m 15m 1h 1d (default 5m)
Exchanges: coinbase, kraken, bitstamp, auto (default)
Benchmark defaults: BTC-USD, 5m; five requests per exchange
Chart keys: h/l older/newer, +/- zoom, i SMA, v volume, r refresh, q quit
Set NO_COLOR=1 for plain output. Charts refresh every 30 seconds.
HELP
}

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ ${1:-} != --help && ${1:-} != -h && $# != 0 ]] || { usage; exit; }
mode=$1
shift
once=0
# Strip the flag only when an argument remains after the subcommand.
if (( $# )) && [[ ${!#} == --once ]]; then
    once=1
    set -- "${@:1:$#-1}"
fi
case $mode in
    stock) (( $# >= 1 && $# <= 2 )) || die "$(usage)"
        symbol=$1 interval=${2-1d} exchange=yahoo ;;
    crypto) (( $# >= 1 && $# <= 3 )) || die "$(usage)"
        symbol=$1 interval=${2-5m} exchange=${3-auto}
        case $exchange in
            auto|coinbase|kraken|bitstamp) ;;
            *) die 'Choose coinbase, kraken, bitstamp or auto.' ;;
        esac ;;
    benchmark) (( $# <= 2 && once == 0 )) || die "$(usage)"
        symbol=${1-BTC-USD} interval=${2-5m} ;;
    *) die "$(usage)" ;;
esac
# Validate before case conversion so command substitution cannot hide a trailing newline.
if [[ $mode == stock ]]; then
    [[ $symbol =~ ^[A-Za-z0-9^][A-Za-z0-9.^=-]{0,23}$ ]] || die 'Invalid stock symbol.'
else
    [[ $symbol =~ ^[A-Za-z0-9]{2,12}-[A-Za-z0-9]{2,12}$ ]] || die 'Use a crypto pair such as BTC-USD.'
fi
case $interval in
    1m) minutes=1 range=1d ;;
    5m) minutes=5 range=5d ;;
    15m) minutes=15 range=5d ;;
    1h) minutes=60 range=1mo ;;
    1d) minutes=1440 range=1y ;;
    *) die 'Unsupported interval. Choose 1m, 5m, 15m, 1h or 1d.' ;;
esac
for dependency in curl jq awk sort mktemp mv date rm tr; do
    command -v "$dependency" >/dev/null || die "Missing dependency: $dependency"
done
symbol=$(printf '%s' "$symbol" | tr '[:lower:]' '[:upper:]') || die 'Cannot normalize symbol.'
[[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || once=1
if [[ $mode != benchmark ]]; then
    awk 'BEGIN { exit (strftime("%Y", 0) != "1970") }' </dev/null 2>/dev/null ||
        die 'An awk with strftime support is required.'
fi
tmp=$(mktemp -d) || die 'Cannot create a temporary workspace.'
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $mode == benchmark ]]; then
    benchmark 5 || die 'Could not complete the benchmark.'
    printf '%-12s %10s %s\n' EXCHANGE MEDIAN_MS SUCCESS
    awk '{ median = $4 ? sprintf("%.1f", $1*1000) : "--"
           printf "%-12s %10s %s/5\n", $3, median, $4 }' "$tmp/ranked" ||
        die 'Could not read the benchmark results.'
    read -r _ tier winner _ < "$tmp/ranked" || die 'Missing benchmark results.'
    case $tier in
        0) printf '\nFastest eligible exchange from this connection: %s\n' "$winner" ;;
        1) printf '\nLowest median among partial results: %s\n' "$winner" ;;
        *) die 'No exchange returned usable candles for this pair and interval.' ;;
    esac
    exit
fi

candle_times=()
candle_count=0 offset=0
last_success=
install_chart() {
    local candidate=$1 timestamp index=0 selected=0 anchor=
    local -a next_times=()
    if (( offset )); then
        anchor=${candle_times[candle_count-offset-1]}
    fi
    while IFS=$'\t' read -r timestamp _; do
        next_times+=("$timestamp")
        # Keep the selected candle, or the closest older candle if it disappeared.
        if [[ -n $anchor ]] && (( timestamp <= anchor )); then
            selected=$index
        fi
        ((index+=1))
    done < "$candidate"
    if (( index == 0 )); then
        reason='empty chart'
        return 1
    fi
    # A delayed upstream response must not rewind a session already showing newer data.
    if (( candle_count && next_times[index-1] < candle_times[candle_count-1] )); then
        reason='feed returned older candles'
        return 1
    fi
    mv -- "$candidate" "$tmp/chart" || { reason='cannot replace chart data'; return 1; }
    candle_times=("${next_times[@]}")
    candle_count=$index
    if [[ -n $anchor ]]; then
        offset=$((candle_count-selected-1))
    fi
}

refresh() {
    reason=
    if fetch "$exchange" "$tmp/current" "$tmp/error" >/dev/null; then
        if install_chart "$tmp/current"; then
            last_success=$(date -u '+%H:%M:%S UTC') || last_success='unknown time'
            status="Fetched $last_success | REST"
            return
        fi
    else
        IFS= read -r reason < "$tmp/error" || :
        reason=${reason:-request failed}
    fi
    status="Stale (last fetch $last_success) | $reason"
    return 1
}

if [[ $exchange == auto ]]; then
    printf 'Measuring %s candle latency...\n' "$symbol" >&2
    benchmark 3 || die 'Could not complete exchange discovery.'
    read -r _ tier exchange _ < "$tmp/ranked" || die 'Missing exchange discovery results.'
    (( tier < 2 )) || die 'No exchange returned usable candles. Try another pair or check your connection.'
    # Use the winning probe even if the provider failed on a later probe.
    install_chart "$tmp/$exchange.candles" || die "Unable to load $exchange chart: $reason"
    IFS= read -r last_success < "$tmp/$exchange.fetched" || last_success='unknown time'
    status="Fetched $last_success | REST"
    (( tier == 0 )) || printf 'Using %s with partial benchmark results.\n' "$exchange" >&2
else
    refresh || die "Unable to fetch $symbol from $exchange: $reason"
fi

color=0
[[ -t 1 && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]] && color=1
bars=60 sma=1 volume=1
last_refresh=$SECONDS
previous_view=
while :; do
    cols=90 rows=32
    # Keep stty on the terminal input. The substitution captures stdout.
    if [[ -t 0 && -t 1 ]] && dimensions=$(stty size 2>/dev/null) &&
        [[ $dimensions =~ ^([1-9][0-9]*)\ ([1-9][0-9]*)$ ]]; then
        rows=${BASH_REMATCH[1]} cols=${BASH_REMATCH[2]}
    fi
    view=$cols:$rows:$bars:$offset:$sma:$volume:$status
    if [[ $view != "$previous_view" ]]; then
        frame=$(render_chart) || die 'Chart rendering failed.'
        if (( once )); then
            printf '%s\n' "$frame" || exit 1
            break
        fi
        printf '\033[H\033[2J%s\n' "$frame" || exit 1
        if (( cols >= 63 )); then
            printf 'h/l History   +/- Zoom   i SMA   v Volume   r Refresh   q Quit'
        elif (( cols >= 19 )); then
            printf 'h/l  +/-  i  v  r  q'
        fi
        previous_view=$view
    fi
    key=
    # Timeout keeps the refresh timer running. EOF or a lost TTY ends the loop.
    if IFS= read -rsn1 -t 1 key; then
        case $key in
            q|Q) break ;;
            h) (( offset < candle_count - 1 )) && ((offset+=1)) ;;
            l) (( offset > 0 )) && ((offset-=1)) ;;
            +|=)
                visible=$bars
                (( visible <= cols - 17 )) || visible=$((cols-17))
                (( visible <= candle_count - offset )) || visible=$((candle_count-offset))
                if (( visible > 10 )); then
                    bars=$((visible-5))
                    (( bars >= 10 )) || bars=10
                fi ;;
            -) (( bars < 300 )) && ((bars+=5)) ;;
            i) ((sma=1-sma)) ;;
            v) ((volume=1-volume)) ;;
        esac
    elif (( $? <= 128 )); then
        break
    fi
    if [[ $key == r ]] || (( SECONDS - last_refresh >= 30 )); then
        refresh || :
        previous_view=
        last_refresh=$SECONDS
    fi
done
