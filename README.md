# sh-pro-trader

A Bash terminal for charting stocks and spot crypto. It fetches OHLCV candles with
`curl` and renders them in the terminal with a price axis, UTC timestamps,
volume, a 20-candle simple moving average and the selected candle's OHLC values.
The percentage next to OHLC is the change from the previous candle's close.

## Run

Requires Bash, curl, jq 1.6+, and an awk with `strftime` support (GNU awk or
current mawk). Use a UTF-8 terminal for chart glyphs.

```sh
git clone https://github.com/evalrjcom/sh-pro-trader.git
cd sh-pro-trader
./trader stock AAPL 1d
./trader crypto BTC-USD 5m
./trader crypto ETH-USD 1h kraken
./trader benchmark BTC-USD 5m
NO_COLOR=1 ./trader crypto BTC-USD 5m coinbase --once
```

| Key | Action |
| --- | --- |
| `h` / `l` | Move the right edge one candle older / newer |
| `+` / `-` | Show fewer / more candles |
| `i` | Toggle the 20-candle moving average |
| `v` | Toggle relative volume |
| `r` | Refresh candles now |
| `q` | Quit |

Both modes support `1m`, `5m`, `15m`, `1h` and `1d`. The terminal refreshes
every 30 seconds and keeps the last successful chart if a refresh fails.
`--once` or redirected output prints a single chart. Green solid candles closed
at or above the open. Red shaded candles closed below the open.

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
Within each group, the lowest median wins. Crypto's default `auto` runs three
requests per exchange at startup and uses the winner for that session. Results
vary by region, connection and time.
