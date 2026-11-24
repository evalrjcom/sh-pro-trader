# sh-pro-trader

A Bash terminal for charting stocks and spot crypto. It fetches OHLCV candles with
`curl` and renders them in the terminal with a price axis, UTC timestamps,
volume, a 20-candle simple moving average and the selected candle's OHLC values.
When the previous close is positive, the percentage next to OHLC shows the
change from that close.

## Run

`trader.sh` contains the complete program as a single file. Download or copy
that file and run it with Bash. Clones also support `./trader` as an alias.

Requires Bash, curl, jq 1.6+, and an awk with `strftime` support (GNU awk or
current mawk or BusyBox awk). Use a UTF-8 terminal for chart glyphs.

```sh
git clone https://github.com/evalrjcom/sh-pro-trader.git
cd sh-pro-trader
chmod +x trader.sh
./trader.sh stock AAPL 1d
./trader.sh crypto BTC-USD 5m
./trader.sh crypto ETH-USD 1h kraken
./trader.sh benchmark BTC-USD 5m
NO_COLOR=1 ./trader.sh crypto BTC-USD 5m coinbase --once
```

| Key | Action |
| --- | --- |
| `h` / `l` | Move the right edge one candle older / newer |
| `+` / `-` | Show fewer / more candles |
| `i` | Toggle the 20-candle moving average |
| `v` | Toggle relative volume |
| `r` | Refresh candles now |
| `q` | Quit |

Crypto accepts `BTC`, `BTCUSD`, and `BTC-USD` as the same pair.
A bare asset defaults to USD. Use `BASE-QUOTE` for other quotes or to
disambiguate an asset name that ends in USD, such as `FDUSD-USDC`.

Both modes support `1m`, `5m`, `15m`, `1h` and `1d`. The terminal refreshes
every 30 seconds. Refreshes keep the selected historical candle when it is
still available. If the request fails or returns older data, the chart keeps
its last successful data and marks it stale.

`--once`, non-interactive use, or `TERM=dumb` prints a single chart. Green solid
candles closed at or above the open. Red shaded candles closed below the open.
A question mark in the volume row indicates an unavailable value. Each candle
occupies one column, so gaps in trading time are compressed.

## Feeds and latency

Stocks use Yahoo Finance's chart endpoint. Yahoo may delay data, throttle
requests or change its endpoint. Crypto uses Coinbase Exchange, Kraken or
Bitstamp public spot endpoints. Public candle requests require no API keys.
Availability depends on the pair, venue and network. The latest candle can still
be forming. This terminal displays market data and does not submit orders.

`benchmark` makes five requests per exchange for the same pair and interval.
It uses curl's total request time, including connection setup and response
transfer, and counts only requests that return valid candles. Exchanges with a
majority of successful requests rank ahead of those with fewer successes.
Within each group, the lowest median wins. The report includes zero-success
venues, labels partial results, and exits with an error if every venue fails.
Crypto's default `auto` runs three requests per exchange at startup and opens
the chart with the newest candle timestamp from the winner. Results vary by region, connection and
time.

## Run the regression tests

Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` from the
repository root. The tests use simulated HTTP responses and a Unix
pseudoterminal, so they require Python 3 and run without market-data access.
