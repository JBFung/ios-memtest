# iOS memtest

A tiny iOS app that checks whether a 4 GB fixed-address memory window, lazy commit through SIGSEGV/SIGBUS, and
multi-GB memory use work on an iPhone, as needed by a port of the [MHGURecomp](https://github.com/morerokk/MHGURecomp)
runtime. Contains no game code or data.

GitHub Actions builds an unsigned `MemTest.ipa` on every push (Actions -> latest run -> Artifacts). Install it with
Sideloadly, run it, and read the results on screen or in `memtest.log` (Files app -> On My iPhone -> MemTest).
