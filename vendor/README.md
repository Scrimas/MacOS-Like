# vendor/

[MacTahoe](https://github.com/vinceliuice/MacTahoe-icon-theme) by vinceliuice,
unmodified, so that MacOS-Like works without it being installed. `MacTahoe/`
and `MacTahoe-dark/` are exactly what MacTahoe's own `install.sh -t default`
puts in `~/.local/share/icons` (minus `icon-theme.cache`), at the commit named
in `VERSION`.

To move to another MacTahoe commit, change `MACTAHOE_COMMIT` in
`tools/update-mactahoe.sh` and run it. It replaces this directory and rebuilds
`prebuilt/` to match.

MacTahoe is licensed under the GPL-3.0 (`MacTahoe/COPYING`); its authors are
listed in `MacTahoe/AUTHORS`.
