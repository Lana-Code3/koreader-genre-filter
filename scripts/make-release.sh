#!/bin/sh
# Builds two zips in ./dist:
#   genre_filter-kobo-<version>.zip    unzip to the root of a Kobo (KFMon/NickelMenu layout: .adds/koreader/...)
#   genre_filter.koplugin-<version>.zip  just the plugin folder, for any other KOReader install
# Usage: scripts/make-release.sh [version]
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-dev}"
rm -rf dist
mkdir -p dist/kobo/.adds/koreader/plugins
cp -r genre_filter.koplugin dist/kobo/.adds/koreader/plugins/
(cd dist/kobo && zip -r -X "../genre_filter-kobo-$VERSION.zip" .adds)
zip -r -X "dist/genre_filter.koplugin-$VERSION.zip" genre_filter.koplugin
rm -rf dist/kobo
ls -l dist
