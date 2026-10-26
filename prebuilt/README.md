# prebuilt/

MacTahoe's own app icons as MacOS-Like changes them (steps 5b-5e of
`setup.sh`): one drop shadow under every tile, the common white and graphite
tiles, brand tiles for the coloured ones, and the dark theme's versions of all
of them.

`setup.sh` lays these files over `vendor/` to make each theme, so an install
takes seconds instead of the ~9 minutes those steps need. Only files that differ
from MacTahoe's are here:

- `Light/` goes over `vendor/MacTahoe`, for MacOS-Like-Light.
- `Dark/` goes over `vendor/MacTahoe` plus `vendor/MacTahoe-dark`, for
  MacOS-Like-Dark.
- `STAMP` says what they were made from: `inputs` is a hash of the MacTahoe
  commit, the tile constants and steps 5b-5e; `mactahoe` is that commit and
  `built` the date.

Don't edit these by hand. Change `setup.sh` and run `./setup.sh --rebuild`,
which remakes this directory; `./setup.sh --check` tells you whether it is
current.

These are modified versions of MacTahoe's icons (GPL-3.0, see
`vendor/MacTahoe/COPYING`), changed by MacOS-Like's `setup.sh` on the date
given in `STAMP`.
