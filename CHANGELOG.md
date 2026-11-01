# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

### Added
- Genre/tag search with include and exclude lists (any/all matching, whole-word
  or exact tag matching).
- Optional word search in title and description (quoted phrases supported).
- Reading status filter (New, Reading, On hold, Finished) combining KOReader's
  status with the native Kobo reader's status from `KoboReader.sqlite`
  (read-only).
- "Browse genres" list with book counts; tap to include, hold to exclude.
- Two result views: standard KOReader results list, and a two-column cover
  gallery (2x4 / 2x3 / 2x2) showing cover, title, author, reading status and tags.
- Synopsis and tags viewer on long-press.
- Back-to-filter arrow in results; "Show results" button equal to the keyboard's
  Return key; keyboard show/hide toggle.
- Remembers the last filter and options; Dispatcher (gesture) action.
- Unit tests for the matching logic and a GitHub Actions workflow.
