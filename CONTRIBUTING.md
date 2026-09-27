# Contributing

Siftr is a small project. Bug reports and focused fixes are welcome.

**Reporting a bug.** Open an issue with your macOS version, your Mac (for
example "M1 MacBook Air"), what you did and what happened. If a song won't
play, say its format (MP3, M4A, FLAC, WAV or OGG). Please don't attach music.

**Changing code.**

- It builds with Apple's free Command Line Tools; how to build, test and
  measure is in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
- `swift test` must pass, and `scripts/self_test.sh` must say ALL PASSED
  (with the screen unlocked and its window uncovered).
- For anything that could change speed or memory, run `scripts/bench.sh` on
  the old and the new build, alternating, and include both sets of numbers.
- Test data stays made up: scratch folders only, generated tones, and
  placeholder names like "Sample Song 01" and "Test Artist". No real music,
  and no personal names or paths.

**Before proposing a feature,** check the [known limits](README.md#limits).
Some are deliberate: one library folder, no streaming services, and
recognizing repeats by file name and size.

By contributing, you agree that your work is released under the
[MIT license](LICENSE).
