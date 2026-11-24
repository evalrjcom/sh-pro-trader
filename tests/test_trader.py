"""Regression tests for normalized feeds, venue selection and the chart CLI."""

import fcntl
import json
import os
from pathlib import Path
import pty
from select import select
import shutil
import struct
import subprocess
import tempfile
import termios
from time import monotonic
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = 1_700_000_000
FOOTER = b"q Quit"


def coinbase(*candles, elapsed="0.250000"):
    return {
        "body": [[stamp, price-1, price+1, price, price, 100] for stamp, price in candles],
        "wire": f"200 {elapsed}",
    }


class TraderTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name)
        mock = self.tmp / "curl"
        shutil.copyfile(ROOT / "tests/mock_curl.py", mock)
        mock.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.tmp}:{os.environ['PATH']}",
                        MOCK_MARKET_DATA=str(self.tmp), TERM="xterm-256color", NO_COLOR="1")
        self.scenario()

    def scenario(self, **venues):
        (self.tmp / "responses.json").write_text(json.dumps(venues))

    def trader(self, *args):
        return subprocess.run([ROOT / "trader", *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_arguments_fail_before_fetch(self):
        for args in (("stock",), ("stock", "AAPL\n"), ("stock", "AAPL", ""),
                     ("crypto", "BTC-USD", "2m"), ("crypto", "BTC-USD", "5m", ""),
                     ("benchmark", "--once")):
            with self.subTest(args=args):
                self.assertEqual(self.trader(*args).returncode, 1)
        self.assertFalse((self.tmp / "yahoo").exists())
        self.assertFalse((self.tmp / "coinbase").exists())

    def test_yahoo_missing_volume_and_valid_flat_zero_price(self):
        url = "https://query1.finance.yahoo.com/v8/finance/chart/%5EGSPC?interval=1d&range=1y"
        self.scenario(yahoo=[{"url": url, "body": {"chart": {"error": None, "result": [{
            "timestamp": [BASE, BASE + 600],
            "indicators": {"quote": [{"open": [None, 0], "high": [None, 0],
                                       "low": [None, 0], "close": [None, 0],
                                       "volume": [None, None]}]},
        }]}}}])
        result = self.trader("stock", "^gspc", "--once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("^GSPC  1d  yahoo  0", result.stdout)
        self.assertIn("Volume n/a", result.stdout)

    def test_normalization_rejects_corrupt_rows_and_sorts(self):
        self.scenario(coinbase=[{"body": [[BASE+60, 100, 102, 101, 102, 10],
                                          [BASE, 99, 101, 100, 100, 0],
                                          [BASE+60, 100, 102, 101, 102, 10],
                                          [BASE+90.5, 102, 104, 103, 103, 1],
                                          [BASE+120, 104, 103, 104, 104, 1],
                                          [BASE+180, 103, 105, 104, 104, "Infinity"],
                                          [BASE+240, 103, 105, 104, "NaN", 1]]}])
        result = self.trader("crypto", "BTC-USD", "1m", "coinbase")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BTC-USD  1m  coinbase  102", result.stdout)
        self.assertIn("+2.00%", result.stdout)

    def test_rejects_multiple_documents_and_redirect(self):
        good = coinbase((BASE, 100))["body"]
        self.scenario(coinbase=[{"raw": json.dumps(good) + "\nfalse"},
                                {"body": good, "wire": "301 0.001000"}])
        invalid = self.trader("crypto", "BTC-USD", "5m", "coinbase")
        redirect = self.trader("crypto", "BTC-USD", "5m", "coinbase")
        self.assertEqual(invalid.returncode, 1)
        self.assertIn("invalid candle response", invalid.stderr)
        self.assertEqual(redirect.returncode, 1)
        self.assertIn("unexpected HTTP status", redirect.stderr)

    def test_auto_renders_saved_probe_when_final_probe_fails(self):
        self.scenario(coinbase=[coinbase((BASE, 100)), coinbase((BASE+300, 101))])
        result = self.trader("crypto", "btc-usd")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BTC-USD  5m  coinbase  101", result.stdout)
        self.assertEqual((self.tmp / "coinbase").read_text(), "3")

    def test_benchmark_prioritizes_majority_and_reports_failures(self):
        successful = {"body": {"error": [], "result": {
            "XXBTZUSD": [[BASE, "1", "2", "1", "2", "0", "12", 10]], "last": BASE+60}},
            "wire": "200 0.090000"}
        self.scenario(coinbase=[coinbase((BASE, 100), elapsed="0.001000")],
                      kraken=[successful, successful, successful])
        result = self.trader("benchmark")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"kraken\s+90\.0 3/5")
        self.assertRegex(result.stdout, r"coinbase\s+1\.0 1/5")
        self.assertRegex(result.stdout, r"bitstamp\s+-- 0/5")
        self.assertIn("connection: kraken", result.stdout)

    def test_benchmark_all_zero_exits_nonzero_and_prints_table(self):
        result = self.trader("benchmark")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("0/5"), 3)
        self.assertIn("No exchange returned usable candles", result.stderr)

    def test_narrow_chart_reserves_the_last_column(self):
        env = dict(self.env, TRADER_CHART_STATUS="Fetched 12:00:00 UTC | REST")
        chart = subprocess.run(
            ["awk", "-v", "cols=34", "-v", "rows=12", "-v", "bars=60", "-v", "volume=1",
             "-v", "symbol=VERYLONGSTOCKSYMBOL123456", "-v", "interval=1m",
             "-v", "exchange=yahoo", "-f", ROOT / "lib/chart.awk"],
            input=f"{BASE}\t1e300\t1e300\t-1e300\t-1e300\t1e300\n",
            env=env, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(chart.returncode, 0, chart.stderr)
        self.assertIn("UTC", chart.stdout)
        for line in chart.stdout.splitlines():
            self.assertLess(len(line), 34, line)

    def test_refresh_keeps_history_anchor_and_stale_data(self):
        self.scenario(coinbase=[
            coinbase((BASE, 100), (BASE+300, 110)),
            coinbase((BASE, 100), (BASE+300, 110), (BASE+600, 120)),
            {},
            coinbase((BASE, 90), (BASE+300, 95)),
        ])
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 74, 0, 0))
        try:
            process = subprocess.Popen([ROOT / "trader", "crypto", "BTC-USD", "5m", "coinbase"],
                                       env=self.env, stdin=slave, stdout=slave, stderr=slave)
        finally:
            os.close(slave)

        def stop():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)

        self.addCleanup(stop)

        def frame(key=b""):
            if key:
                os.write(master, key)
            captured = bytearray()
            deadline = monotonic() + 5
            while FOOTER not in captured:
                ready, _, _ = select([master], [], [], max(0, deadline-monotonic()))
                self.assertTrue(ready, captured.decode(errors="replace"))
                captured.extend(os.read(master, 65536))
            return captured.split(b"h/l History")[0]

        self.assertIn(b"coinbase  110", frame())
        older = frame(b"h")
        self.assertIn(b"coinbase  100", older)
        self.assertIn(b"| History", older)
        self.assertIn(b"coinbase  100", frame(b"r"))
        self.assertIn(b"coinbase  110", frame(b"l"))
        self.assertIn(b"coinbase  120", frame(b"l"))
        failed = frame(b"r")
        self.assertIn(b"Stale (last fetch", failed)
        self.assertIn(b"coinbase  120", failed)
        older = frame(b"r")
        self.assertIn(b"feed returned older candles", older)
        self.assertIn(b"coinbase  120", older)
        os.write(master, b"q")
        self.assertEqual(process.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main()
