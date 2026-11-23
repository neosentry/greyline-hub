import json
import unittest
from datetime import datetime, timedelta, timezone

from greyline_hub.config import ConfigError, discover_config, load_config, prepare, strip_json_comments
from greyline_hub.cty import load_cty, location_call
from greyline_hub.feeds import estimate_bands, parse_eisn, parse_hamqsl, parse_kp, parse_sfi, parse_xray
from greyline_hub.maidenhead import grid_to_latlon, latlon_to_grid
from greyline_hub.paths import CTY_PATH, ROOT
from greyline_hub.solar import daylight_state, elevation, solar_position, sunrise_sunset, terminator_grid
from greyline_hub.spots import (
    band_for_khz,
    mode_from_text,
    normalize_http_spot,
    parse_telnet_line,
    xray_class,
)


class ConfigTests(unittest.TestCase):
    def test_comments_and_example(self):
        text = """
        {
          // port
          "server": {"port": 9001, "host": "127.0.0.1"},
          "pages": [{"id": "only", "title": "Only", "slug": "only", "panels": ["map"]}]
        }
        """
        raw = json.loads(strip_json_comments(text))
        cfg = prepare(raw)
        self.assertEqual(cfg["server"]["port"], 9001)
        self.assertEqual(cfg["pages"][0]["slug"], "only")
        self.assertEqual(cfg["pages"][0]["panels"], ["map"])

    def test_example_file_loads(self):
        cfg, path, used_example = load_config(ROOT / "config.example.json")
        self.assertTrue(used_example)
        self.assertEqual(cfg["server"]["port"], 8754)
        slugs = [page["slug"] for page in cfg["pages"]]
        self.assertEqual(slugs, ["", "map"])
        self.assertEqual(path.name, "config.example.json")

    def test_discover_finds_example_without_local_config(self):
        cfg, path, used_example = discover_config()
        self.assertTrue(path.name.endswith(".json"))
        self.assertIn("station_resolved", cfg)
        self.assertTrue(used_example or path.name == "config.json")

    def test_duplicate_slug_rejected(self):
        with self.assertRaises(ConfigError):
            prepare({"pages": [{"id": "a", "slug": "x"}, {"id": "b", "slug": "x"}]})

    def test_needs_a_way_to_serve(self):
        with self.assertRaises(ConfigError):
            prepare({"server": {"enabled": False}, "publish": {"enabled": False}})


class MaidenheadTests(unittest.TestCase):
    def test_fn31pr_roundtrip(self):
        lat, lon = grid_to_latlon("FN31pr")
        self.assertAlmostEqual(lat, 41.729166, places=3)
        self.assertAlmostEqual(lon, -72.708333, places=3)
        self.assertEqual(latlon_to_grid(lat, lon), "FN31pr")

    def test_field_center(self):
        lat, lon = grid_to_latlon("FN")
        self.assertAlmostEqual(lat, 45.0)
        self.assertAlmostEqual(lon, -70.0)

    def test_approximate_florida_point_is_el87uu(self):
        # 27.85 N, 82.30 W. Subsquares run A–X, so this is past the old A–R limit.
        self.assertEqual(latlon_to_grid(27.85, -82.30), "EL87uu")
        lat, lon = grid_to_latlon("EL87uu")
        self.assertAlmostEqual(lat, 27.854167, places=4)
        self.assertAlmostEqual(lon, -82.291667, places=4)
        self.assertEqual(latlon_to_grid(lat, lon), "EL87uu")
        self.assertLess(abs(lat - 27.85), 0.025)
        self.assertLess(abs(lon - (-82.30)), 0.05)


class SolarTests(unittest.TestCase):
    def test_seasonal_declination(self):
        june = solar_position(datetime(2026, 6, 21, 12, tzinfo=timezone.utc))
        december = solar_position(datetime(2026, 12, 21, 12, tzinfo=timezone.utc))
        november = solar_position(datetime(2026, 11, 22, 12, tzinfo=timezone.utc))
        self.assertGreater(june["declination"], 23.0)
        self.assertLess(june["declination"], 23.5)
        self.assertLess(december["declination"], -23.0)
        self.assertGreater(december["declination"], -23.5)
        self.assertLess(november["declination"], -18.0)
        self.assertGreater(november["declination"], -22.0)
        self.assertGreater(november["subsolar_longitude"], -8)
        self.assertLess(november["subsolar_longitude"], 2)

    def test_subsolar_point_is_overhead(self):
        when = datetime(2026, 6, 21, 16, tzinfo=timezone.utc)
        pos = solar_position(when)
        elev = elevation(pos["subsolar_latitude"], pos["subsolar_longitude"], pos["declination"], pos["subsolar_longitude"])
        self.assertGreater(elev, 89)

    def test_summer_terminator_and_equinox_fill(self):
        grid = terminator_grid(23.44, 0.0)
        self.assertAlmostEqual(grid["day"][90], -66.56, delta=1.5)
        self.assertTrue(grid["night_south"])
        equinox = terminator_grid(0.0, 0.0, step=10)
        self.assertEqual(equinox["fill"][18], "day")
        self.assertEqual(equinox["fill"][36], "night")

    def test_equator_sunrise(self):
        rise, sunset = sunrise_sunset(0, 0, datetime(2026, 3, 20, 12, tzinfo=timezone.utc))
        self.assertIsNotNone(rise)
        rise_hours = rise.hour + rise.minute / 60
        set_hours = sunset.hour + sunset.minute / 60
        self.assertGreater(rise_hours, 5.4)
        self.assertLess(rise_hours, 6.6)
        self.assertGreater(set_hours, 17.4)
        self.assertLess(set_hours, 18.6)

    def test_greyline_window(self):
        self.assertEqual(daylight_state(0), "greyline")
        self.assertEqual(daylight_state(20), "day")
        self.assertEqual(daylight_state(-30), "night")


class CountryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.countries = load_cty(CTY_PATH)

    def test_known_calls(self):
        united = self.countries.lookup_call("W1AW")
        self.assertEqual(united.name, "United States")
        self.assertLess(united.lon, 0)
        japan = self.countries.lookup_call("JA1ABC")
        self.assertEqual(japan.name, "Japan")
        self.assertGreater(japan.lon, 0)
        canary = self.countries.lookup_call("EA8/DL1ABC")
        self.assertEqual(canary.name, "Canary Islands")
        self.assertEqual(self.countries.lookup_call("DL1ABC/EA8").name, "Canary Islands")
        self.assertEqual(self.countries.lookup_call("3D2CCC").name, "Conway Reef")
        self.assertNotEqual(self.countries.lookup_call("3D2ABC").name, "Conway Reef")
        hawaii = self.countries.lookup_call("KH6/W1AW")
        self.assertEqual(hawaii.name, "Hawaii")

    def test_portable_suffix(self):
        self.assertEqual(location_call("DL1ABC/P"), "DL1ABC")


class SpotTests(unittest.TestCase):
    def test_http_spot_flips_west_longitude(self):
        spot = normalize_http_spot(
            {
                "id": 5,
                "dx_call": "N6YMM",
                "frequency": 14250.7,
                "dx_latitude": 34.75,
                "dx_longitude": 82.25,
                "de_call": "KY0Q-@",
                "info": "USB",
                "time": "2026-11-22T21:27:50",
                "dx_country": "United States",
            }
        )
        self.assertAlmostEqual(spot["lon"], -82.25)
        self.assertEqual(spot["band"], "20m")
        self.assertEqual(spot["mode"], "USB")
        self.assertEqual(spot["spotter"], "KY0Q")
        self.assertTrue(spot["time"].endswith("Z"))

    def test_telnet_line(self):
        line = "DX de K1TTT:     14074.0  JA1ABC       FT8 -12 dB  2114Z"
        spot = parse_telnet_line(line, datetime(2026, 11, 22, 21, 20, tzinfo=timezone.utc))
        self.assertEqual(spot["dx"], "JA1ABC")
        self.assertEqual(spot["mode"], "FT8")
        self.assertEqual(spot["band"], "20m")
        self.assertEqual(spot["time"], "2026-11-22T21:14:00Z")

    def test_bands_and_modes(self):
        self.assertEqual(band_for_khz(7074), "40m")
        self.assertEqual(band_for_khz(5357), "60m")
        self.assertEqual(mode_from_text("ARRL Sweepstakes SSB"), "SSB")
        self.assertEqual(mode_from_text("FT8 -05dB from JN45"), "FT8")
        self.assertEqual(xray_class(1.97e-7), "B2.0")

    def test_rollover_yesterday(self):
        spot = parse_telnet_line(
            "DX de W1AW:      7074.0  JA1ABC       FT8              2330Z",
            datetime(2026, 11, 22, 0, 10, tzinfo=timezone.utc),
        )
        self.assertEqual(spot["time"], "2026-11-21T23:30:00Z")
        self.assertGreater(timedelta(hours=1), timedelta(0))


class FeedParserTests(unittest.TestCase):
    def test_noaa_shapes(self):
        sfi = parse_sfi(b'[{"flux":94,"time_tag":"2026-11-22T20:00:00"}]')
        self.assertEqual(sfi["value"], 94)
        kp = parse_kp(
            json.dumps(
                [
                    {"time_tag": "2026-11-22T18:00:00", "Kp": 0.67, "a_running": 3, "station_count": 8}
                ]
            )
        )
        self.assertAlmostEqual(kp["kp"], 0.67)
        self.assertEqual(kp["ap"], 3)
        legacy = parse_kp(
            json.dumps(
                [
                    ["time_tag", "Kp", "a_running", "station_count"],
                    ["2026-11-22 15:00:00", "1.33", "5", "8"],
                ]
            )
        )
        self.assertAlmostEqual(legacy["kp"], 1.33)
        xray = parse_xray(
            json.dumps(
                [
                    {"time_tag": "2026-11-22T21:24:00Z", "flux": 1e-9, "energy": "0.05-0.4nm"},
                    {"time_tag": "2026-11-22T21:24:00Z", "flux": 1.971e-7, "energy": "0.1-0.8nm"},
                ]
            )
        )
        self.assertEqual(xray["value"], "B2.0")

    def test_sidc_and_hamqsl(self):
        eisn = parse_eisn("2026 11 22 2026.892  37   7.7  19  20\n")
        self.assertEqual(eisn["value"], 37.0)
        self.assertEqual(eisn["at"], "2026-11-22T00:00:00Z")
        xml = """<?xml version="1.0"?>
        <solar><solardata>
          <updated> 22 Nov 2026 2127 GMT</updated>
          <solarflux>99</solarflux>
          <aindex> 6</aindex>
          <kindex> 0</kindex>
          <xray>B2.2</xray>
          <sunspots>23</sunspots>
          <solarwind>352.8</solarwind>
          <magneticfield> -2.1</magneticfield>
          <geomagfield>INACTIVE</geomagfield>
          <signalnoise>S0-S1</signalnoise>
          <muf>NoRpt</muf>
          <calculatedconditions>
            <band name="80m-40m" time="day">Good</band>
            <band name="80m-40m" time="night">Fair</band>
          </calculatedconditions>
          <calculatedvhfconditions>
            <phenomenon name="E-Skip" location="europe">Band Closed</phenomenon>
          </calculatedvhfconditions>
        </solardata></solar>"""
        parsed = parse_hamqsl(xml)
        self.assertEqual(parsed["aindex"], 6)
        self.assertIsNone(parsed["muf"])
        self.assertEqual(parsed["bands"][0]["night"], "Fair")
        self.assertEqual(parsed["vhf"][0]["condition"], "Band Closed")

    def test_estimate_degrades_when_k_is_high(self):
        quiet = estimate_bands(160, 1)
        storm = estimate_bands(160, 7)
        quiet_10 = next(row for row in quiet if row["name"] == "12m-10m")
        storm_10 = next(row for row in storm if row["name"] == "12m-10m")
        self.assertEqual(quiet_10["day"], "Good")
        self.assertEqual(storm_10["day"], "Poor")


if __name__ == "__main__":
    unittest.main()
