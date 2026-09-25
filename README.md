# Spectrum

A real-time deep-zoom fractal explorer for Apple silicon. Mandelbrot, Multibrot (z³–z⁸), Tricorn,
Burning Ship, Celtic and Julia sets, zoomable to 10^1000 and beyond at display frame rate, with
high-resolution image export and HEVC/ProRes zoom videos.

## Build and run

Requires macOS 26, Xcode (or the command-line tools plus Xcode's SwiftUI plug-ins) and
`brew install gmp mpfr`.

```bash
./scripts/build_app.sh
open build/Spectrum.app
```

`fscli` renders, verifies and benchmarks headlessly, for example:

```bash
swift build -c release --product fscli
.build/release/fscli render --re -0.743643887037158704752191506114774 --im 0.131825904205311970493132056385139 --zoom 30 --size 3840x2160 --samples 16 --out crown.png
```

## Controls

| Input | Action |
| --- | --- |
| Drag, two-finger scroll | Pan |
| Scroll wheel, pinch, ⌘-scroll | Zoom at the pointer |
| Double-click / right-click | Zoom in / out |
| Rotate gesture, Q / E | Rotate |
| Hold ⌥ / ⌥-click | Preview / open the Julia set of the point under the pointer |
| Hold ⇧ | Orbit of the point under the pointer |
| T | Guided tour |
| P | Autopilot: endless dive along intricate boundary detail, stopping at minibrots on the way (, / . for speed) |
| M | Find the nearest mini-Mandelbrot in view and fly to it |
| B | Save the view to Your Places |
| H | Home |
| C / X | Next / previous palette |
| [ / ] | Halve / double iterations |
| L | Relief lighting |
| Space | Hide the interface |
| ⌘S / ⌘E | Export image / zoom video |
| ⌘[ / ⌘] | Back / forward through visited views |
| ⇧⌘C / ⌘L | Copy / go to coordinates |
| ⌥⌘C | Copy image |

## How it works

- **Perturbation with rebasing.** One arbitrary-precision reference orbit (MPFR, on the CPU) per
  view; every pixel iterates only its difference from it in 32-bit floats on the GPU, rebasing to
  the orbit's start whenever that keeps the difference smaller. Differences below 10⁻¹⁸ switch to
  a float-mantissa/integer-exponent representation, so depth is limited only by memory.
- **Bilinear approximation.** A GPU-built table of linear maps skips thousands of iterations at
  once while a pixel stays close to the reference orbit.
- **Interior detection.** The orbit derivative with respect to z, measured from the last close
  approach to 0, identifies attracting cycles, so pixels inside minibrots stop early.
- **Progressive rendering.** Each display frame reprojects the latest finished image to the camera
  (on its own command queue); compute passes render a resolution-budgeted preview while moving,
  then full-resolution tiles and jittered anti-aliasing samples at rest.
- **Colour.** Smooth iteration counts through OKLab-interpolated palettes, relief lighting from the
  distance estimate, colour normalisation that follows the view's iteration range.
- **Staying interactive.** The iteration limit follows the view but is capped so that even the
  smallest preview fits a display frame; exports run in short GPU chunks while the view moves.
- **Autopilot.** Steers by the preview's iteration map towards detailed boundary, away from interior
  and noise, and in the Mandelbrot set locks onto minibrots found by period detection, Newton's
  method and size and shape estimates.
