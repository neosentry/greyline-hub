"""Command line entry for ``python3 -m greyline_hub`` and the ``greyline-hub`` launcher."""

from __future__ import annotations

import argparse
import logging
import sys

from greyline_hub import __version__
from greyline_hub.config import ConfigError, discover_config
from greyline_hub.hub import Service, run_check


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="greyline-hub",
        description="Serve Greyline Hub dashboard pages, or write them into a folder.",
    )
    parser.add_argument("--config", help="path to config.json (default: ./config.json)")
    parser.add_argument("--host", help="override server.host")
    parser.add_argument("--port", type=int, help="override server.port")
    parser.add_argument("--base-path", help="override server.base_path, for example /greyline")
    parser.add_argument("--publish", metavar="DIR", help="also write the site into DIR")
    parser.add_argument("--no-serve", action="store_true", help="do not listen on a port")
    parser.add_argument("--no-publish", action="store_true", help="do not write the publish folder")
    parser.add_argument("--check", action="store_true", help="fetch the feeds once and print a summary")
    parser.add_argument("--version", action="version", version=f"greyline-hub {__version__}")
    return parser.parse_args(argv)


def apply_overrides(cfg: dict, args: argparse.Namespace) -> dict:
    if args.host:
        cfg["server"]["host"] = args.host
    if args.port is not None:
        if not 0 <= args.port <= 65535:
            raise ConfigError("--port must be from 0 to 65535")
        cfg["server"]["port"] = args.port
    if args.base_path is not None:
        from greyline_hub.config import normalize_base_path

        cfg["server"]["base_path"] = normalize_base_path(args.base_path)
    if args.publish:
        cfg["publish"]["enabled"] = True
        cfg["publish"]["directory"] = args.publish
    if args.no_publish:
        cfg["publish"]["enabled"] = False
    if args.no_serve:
        cfg["server"]["enabled"] = False
    if not cfg["server"]["enabled"] and not cfg["publish"]["enabled"]:
        raise ConfigError("nothing to do: remove --no-serve, or pass --publish DIR")
    return cfg


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    args = parse_args(argv)
    try:
        cfg, path, used_example = discover_config(args.config)
        cfg = apply_overrides(cfg, args)
    except ConfigError as exc:
        print(f"greyline-hub: {exc}", file=sys.stderr)
        return 2
    if used_example and not args.check:
        logging.getLogger("greyline").warning(
            "using %s — copy it to config.json and set your callsign, grid, and port",
            path,
        )
    if args.check:
        return run_check(cfg)
    station = cfg["station_resolved"]
    logging.getLogger("greyline").info(
        "Greyline Hub %s  %s %s",
        __version__,
        station["callsign"],
        station["grid"],
    )
    Service(cfg, path).run()
    return 0
