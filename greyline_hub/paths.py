"""Install locations. The package can be launched from any working directory."""

from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parent
STATIC_DIR = PACKAGE / "static"
DATA_DIR = PACKAGE / "data"
CTY_PATH = DATA_DIR / "cty.dat"
LAND_PATH = DATA_DIR / "land.geojson"
