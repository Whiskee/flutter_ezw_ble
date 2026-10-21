"""Regression checks for missing evidence and mixed independent receiver order."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("parse_bond_timing", Path(__file__).with_name("parse_bond_timing.py"))
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


class ProbeReportTest(unittest.TestCase):
    def event(self, stage, ms, **extra):
        # All timestamps represent event occurrence; log line ordering is deliberately unrelated.
        return dict(probeId="a", endpoint="left", anchorMonoNs=1, anchorWallMs=100,
                    stage=stage, monoNs=ms * 1_000_000, source="capture", line=7, **extra)

    def test_out_of_order_capture_uses_monotonic_and_preserves_unknowns(self):
        rows = parser.summarize([
            self.event("receiver_main", 4010, bondState=12),
            self.event("public_bond_state", 1000, bondState=12),
            self.event("receiver_background", 4020, bondState=12),
            self.event("public_bond_state", 0, bondState=11),
        ])
        self.assertEqual(rows[0]["public_to_background_ms"], 3020)
        self.assertEqual(rows[0]["background_to_main_ms"], -10)
        self.assertEqual(rows[0]["discover_call_ms"], "")
        self.assertEqual(rows[0]["stop_reason"], "missing_stop_record")

    def test_reused_probe_id_in_other_capture_anchor_is_not_merged(self):
        first = self.event("probe_start", 0)
        second = self.event("probe_start", 1)
        second["anchorWallMs"] = 999
        self.assertEqual(len(parser.summarize([first, second])), 2)

    def test_bonded_monitor_wait_ignores_earlier_bonding_callback(self):
        rows = parser.summarize([
            self.event("device_monitor_wait", 0, bondState=11),
            self.event("device_monitor_acquired", 1, bondState=11),
            self.event("device_monitor_wait", 1000, bondState=12),
            self.event("device_monitor_acquired", 1300, bondState=12),
        ])
        self.assertEqual(rows[0]["device_monitor_wait_ms"], 300)

    def test_reads_threadtime_prefix_and_keeps_file_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "logcat.txt"
            path.write_text("other log\n10-21 00:00:00.000 1 2 D BleBondTiming: " +
                            json.dumps(self.event("probe_start", 0)) + "\n")
            events = parser.read_events([path])
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["source"], str(path))
            self.assertEqual(events[0]["line"], 2)


if __name__ == "__main__":
    unittest.main()
