# StripShot

A tool written in V that uses FFmpeg to remove device and OS fingerprints from screenshots. When you take a screenshot, several subtle traces are left in the image that can reveal what device, operating system, or display configuration was used. This tool neutralizes those traces.

## Problem

Screenshots contain hidden fingerprints that can identify the source device:

- Subpixel rendering patterns (ClearType on Windows, LCD smoothing on macOS, FreeType on Linux) leave colored fringes on text edges that differ between operating systems.
- Pixel format ordering (BGR vs RGB vs BGRA) varies by OS and graphics framework.
- Embedded ICC color profiles identify the monitor and operating system.
- Gamma curves differ between platforms (macOS ~1.8, Windows ~2.2, some phones ~2.4).
- Color space tags (Display P3 for Apple devices, sRGB for Windows) reveal the device ecosystem.
- Bit depth and DPI metadata can indicate Retina/HiDPI displays.
- PNG/JPEG encoder signatures differ between screenshot tools.
- Font hinting and rasterization patterns are OS-specific.

Even if you crop out all visible UI elements, these pixel-level and metadata-level traces remain.

## How It Works

The tool applies a multi-stage pipeline through FFmpeg:

1. Force pixel format to RGB24, neutralizing BGR/BGRA/RGB0 differences.
2. Normalize color space to BT.709/sRGB, removing Display P3 and Adobe RGB traces.
3. Apply a subtle Gaussian blur (sigma 0.4) to destroy subpixel rendering patterns, followed by an unsharp mask to recover perceived sharpness.
4. Normalize gamma to a standard 2.2 curve.
5. Inject minimal random noise to break statistical encoder fingerprints.
6. Strip all metadata including EXIF, ICC profiles, XMP, and encoder tags.
7. Set bitexact flags to prevent FFmpeg from writing its own identifying markers.
8. Re-tag output with generic sRGB color information.

The blur at sigma 0.4 is effectively invisible to the human eye but completely destroys the colored fringe patterns left by subpixel text rendering.

## Requirements

- V compiler (https://vlang.io)
- FFmpeg and FFprobe in PATH

## Build

```
v -prod src/main.v -o screenshot_sanitizer
```

## Usage

Basic usage:

```
screenshot_sanitizer -i screenshot.png -o clean.png
```

With custom parameters:

```
screenshot_sanitizer -i input.png -o output.png --blur 0.5 --noise 3
```

Process all images in a directory:

```
screenshot_sanitizer --batch ./screenshots/
```

Metadata strip only (no pixel modification):

```
screenshot_sanitizer -i input.png -o output.png --no-blur --no-noise --no-color-norm
```

See ffmpeg commands being executed:

```
screenshot_sanitizer -i input.png -o output.png --verbose
```

## Options

```
-i, --input <file>       Input image path
-o, --output <file>      Output image path (default: <input>_clean.<ext>)
--batch <dir>            Process all images in a directory
--blur <sigma>           Gaussian blur sigma for subpixel removal (default: 0.4)
--noise <strength>       Random noise strength, 0-10 (default: 2)
--gamma <value>          Target gamma value (default: 2.2)
--quality <1-100>        JPEG/WebP output quality (default: 95)
--no-blur                Skip subpixel rendering neutralization
--no-noise               Skip noise injection
--no-strip               Keep original metadata (not recommended)
--no-color-norm          Skip color space normalization
--keep-alpha             Preserve alpha channel instead of flattening
--verbose                Print ffmpeg commands to stdout
-h, --help               Show help
```

## Supported Formats

Input and output: PNG, JPEG, WebP, BMP, TIFF.

The tool detects the format from the file extension and adjusts encoder parameters accordingly.

## Output Analysis

When processing an image, the tool first analyzes it and reports detected fingerprints:

```
[>] Processing: screenshot.png
  [i] Detected: BGR pixel order (Windows-style) | ICC profile embedded | pix_fmt=bgra
  [>] Saved: clean.png (245.3KB) in 82ms
```

## Limitations

- The tool operates on raster data only. Vector-based fingerprints in SVG or PDF screenshots are not addressed.
- If the screenshot contains visible OS-specific UI elements (window decorations, fonts, taskbar), those are not modified. Crop them before processing.
- Very aggressive blur values (above 1.0) will visibly soften text. Stay in the 0.3-0.6 range for text-heavy screenshots.
- Re-encoding a JPEG will always introduce some generation loss regardless of quality setting.

## How to Verify

To confirm fingerprints have been removed, you can inspect before and after with:

```
ffprobe -v quiet -print_format json -show_streams -show_format original.png
ffprobe -v quiet -print_format json -show_streams -show_format clean.png
```

Check that the clean version shows no ICC profile, uses rgb24 pixel format, has BT.709 color tags, and contains no identifying metadata.

For subpixel verification, zoom into text edges at 400-800% in an image editor. Original screenshots from Windows will show red-green-blue fringe patterns on character edges. After processing, these fringes should be gone.

## License
![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)

```
