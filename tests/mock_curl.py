#!/usr/bin/env python3
"""Supply scripted HTTP responses through the curl command-line interface."""

import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit

args = sys.argv[1:]
url = urlsplit(args[-1])
venues = {
    "query1.finance.yahoo.com": "yahoo",
    "api.exchange.coinbase.com": "coinbase",
    "api.kraken.com": "kraken",
    "www.bitstamp.net": "bitstamp",
}
venue = venues[url.hostname]
root = Path(os.environ["MOCK_MARKET_DATA"])
counter = root / venue
index = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(index + 1))
requests = json.loads((root / "responses.json").read_text()).get(venue, [])
response = requests[index] if len(requests) > index else {}
if "url" in response and args[-1] != response["url"]:
    sys.exit(f"unexpected URL: {args[-1]}")
if not response:
    print("fixture HTTP failure", file=sys.stderr)
    sys.exit(22)
destination = Path(args[args.index("--output") + 1])
destination.write_text(response.get("raw", json.dumps(response.get("body"))))
print(response.get("wire", "200 0.250000"), end="")
