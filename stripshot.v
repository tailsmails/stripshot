//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

// v -prod -gc boehm -prealloc -skip-unused -d no_backtrace -d no_debug -cc clang -cflags "-O2 -fPIE -fno-stack-protector -fno-ident -fno-common -fvisibility=hidden" -ldflags "-pie -Wl,-z,relro -Wl,-z,now -Wl,--gc-sections -Wl,--build-id=none" stripshot.v -o stripshot && strip --strip-all --remove-section=.comment --remove-section=.note --remove-section=.gnu.version --remove-section=.note.ABI-tag --remove-section=.note.gnu.build-id --remove-section=.note.android.ident --remove-section=.eh_frame --remove-section=.eh_frame_hdr stripshot

module main

import os
import rand
import time

const version = '1.0.0'
const temp_prefix = '_ssan_'

struct SanitizeConfig {
mut:
	input_path       string
	output_path      string
	blur_sigma       f64  = 0.4
	noise_strength   int  = 2
	target_gamma     f64  = 2.2
	quality          int  = 95
	strip_metadata   bool = true
	kill_subpixel    bool = true
	normalize_color  bool = true
	add_noise        bool = true
	flatten_alpha    bool = true
	force_8bit       bool = true
	randomize_encode bool = true
	batch_mode       bool
	batch_dir        string
	verbose          bool
}

fn main() {
	args := os.args[1..]

	if args.len == 0 || '-h' in args || '--help' in args {
		print_usage()
		return
	}

	mut cfg := parse_args(args)

	probe := os.execute('ffmpeg -version')
	if probe.exit_code != 0 {
		eprintln('[✗] ffmpeg not found in PATH')
		exit(1)
	}

	if cfg.batch_mode {
		batch_sanitize(mut cfg)
	} else {
		sanitize_single(cfg) or {
			eprintln('[✗] ${err}')
			exit(1)
		}
	}
}

fn print_usage() {
	println('
╔══════════════════════════════════════════════╗
║              StripShot v${version}                ║
║   Strips device/OS fingerprints from images  ║
╚══════════════════════════════════════════════╝

Usage:
  stripshot -i <input> -o <output> [options]
  stripshot --batch <directory> [options]

Options:
  -i, --input <file>       Input image
  -o, --output <file>      Output image
  --batch <dir>            Process all images in directory
  --blur <sigma>           Subpixel blur sigma (default: 0.4)
  --noise <strength>       Noise strength 0-10 (default: 2)
  --gamma <value>          Target gamma (default: 2.2)
  --quality <1-100>        JPEG quality (default: 95)
  --no-blur                Skip subpixel neutralization
  --no-noise               Skip noise injection
  --no-strip               Keep metadata
  --no-color-norm          Skip color normalization
  --keep-alpha             Don\'t flatten alpha channel
  --verbose                Show ffmpeg commands
  -h, --help               Show this help

Examples:
  stripshot -i screen.png -o clean.png
  stripshot -i photo.png -o out.png --blur 0.6 --noise 3
  stripshot --batch ./screenshots/
')
}

fn parse_args(args []string) SanitizeConfig {
	mut cfg := SanitizeConfig{}
	mut i := 0
	for i < args.len {
		match args[i] {
			'-i', '--input' {
				i++
				if i < args.len {
					cfg.input_path = args[i]
				}
			}
			'-o', '--output' {
				i++
				if i < args.len {
					cfg.output_path = args[i]
				}
			}
			'--batch' {
				cfg.batch_mode = true
				i++
				if i < args.len {
					cfg.batch_dir = args[i]
				}
			}
			'--blur' {
				i++
				if i < args.len {
					cfg.blur_sigma = args[i].f64()
				}
			}
			'--noise' {
				i++
				if i < args.len {
					cfg.noise_strength = args[i].int()
				}
			}
			'--gamma' {
				i++
				if i < args.len {
					cfg.target_gamma = args[i].f64()
				}
			}
			'--quality' {
				i++
				if i < args.len {
					cfg.quality = args[i].int()
				}
			}
			'--no-blur' {
				cfg.kill_subpixel = false
			}
			'--no-noise' {
				cfg.add_noise = false
			}
			'--no-strip' {
				cfg.strip_metadata = false
			}
			'--no-color-norm' {
				cfg.normalize_color = false
			}
			'--keep-alpha' {
				cfg.flatten_alpha = false
			}
			'--verbose' {
				cfg.verbose = true
			}
			else {}
		}
		i++
	}
	return cfg
}

fn sanitize_single(cfg SanitizeConfig) ! {
	if cfg.input_path == '' {
		return error('No input file specified')
	}
	if !os.exists(cfg.input_path) {
		return error('Input file not found: ${cfg.input_path}')
	}

	out := if cfg.output_path != '' {
		cfg.output_path
	} else {
		ext := os.file_ext(cfg.input_path)
		base := cfg.input_path.trim_string_right(ext)
		'${base}_clean${ext}'
	}

	println('[▸] Processing: ${cfg.input_path}')
	sw := time.new_stopwatch()

	info := analyze_image(cfg.input_path, cfg.verbose)
	println('  [i] Detected: ${info}')

	filters := build_filter_chain(cfg)
	cmd := build_ffmpeg_cmd(cfg, filters, cfg.input_path, out)

	if cfg.verbose {
		println('  [cmd] ${cmd}')
	}

	result := os.execute(cmd)
	if result.exit_code != 0 {
		println('  [!] Complex pipeline failed, trying fallback...')
		fallback_cmd := build_fallback_cmd(cfg, cfg.input_path, out)
		result2 := os.execute(fallback_cmd)
		if result2.exit_code != 0 {
			return error('FFmpeg failed: ${result2.output}')
		}
	}

	if cfg.strip_metadata {
		strip_residual_metadata(out, cfg.verbose)
	}

	elapsed := sw.elapsed().milliseconds()
	out_size := os.file_size(out)
	println('  [✓] Saved: ${out} (${format_size(out_size)}) in ${elapsed}ms')
}

fn analyze_image(path string, verbose bool) string {
	cmd := 'ffprobe -v quiet -print_format json -show_streams -show_format "${path}"'
	r := os.execute(cmd)
	if r.exit_code != 0 {
		return 'unknown format'
	}

	mut info_parts := []string{}
	output := r.output

	if output.contains('rgb') || output.contains('RGB') {
		info_parts << 'RGB pixel order'
	}
	if output.contains('bgr') || output.contains('BGR') {
		info_parts << 'BGR pixel order (Windows-style)'
	}
	if output.contains('gbr') || output.contains('GBR') {
		info_parts << 'GBR pixel order'
	}
	if output.contains('icc_profile') || output.contains('ICC') {
		info_parts << 'ICC profile embedded'
	}
	if output.contains('bt709') {
		info_parts << 'BT.709 color'
	}
	if output.contains('smpte') {
		info_parts << 'SMPTE color (broadcast)'
	}
	if output.contains('display_p3') || output.contains('Display P3') {
		info_parts << 'Display P3 (Apple device likely)'
	}
	if output.contains('"bits_per_raw_sample": "10"') {
		info_parts << '10-bit color (HDR device)'
	}

	pix_fmts := ['rgb24', 'bgr24', 'rgba', 'bgra', 'rgb48', 'rgba64', 'gbrap', 'rgb0', '0rgb',
		'bgr0', '0bgr', 'ya8', 'gray']
	for fmt in pix_fmts {
		if output.contains('"pix_fmt": "${fmt}"') {
			info_parts << 'pix_fmt=${fmt}'
			break
		}
	}

	if info_parts.len == 0 {
		return 'standard image (no obvious fingerprints)'
	}
	return info_parts.join(' | ')
}

fn build_filter_chain(cfg SanitizeConfig) string {
	mut filters := []string{}

	filters << 'format=rgb24'

	if cfg.normalize_color {
		filters << 'colorspace=all=bt709:iall=bt709:fast=0'
	}

	if cfg.kill_subpixel {
		filters << 'gblur=sigma=${cfg.blur_sigma}'
		filters << 'unsharp=3:3:0.5:3:3:0.0'
	}

	filters << 'eq=gamma=1.0:gamma_r=1.0:gamma_g=1.0:gamma_b=1.0'

	if cfg.add_noise && cfg.noise_strength > 0 {
		seed := rand.int_in_range(0, 99999) or { 12345 }
		filters << 'noise=alls=${cfg.noise_strength}:allf=t+u:seed=${seed}'
	}

	filters << 'format=rgb24'

	return filters.join(',')
}

fn build_ffmpeg_cmd(cfg SanitizeConfig, filters string, input string, output string) string {
	mut parts := []string{}
	parts << 'ffmpeg -y -hide_banner -loglevel error'
	parts << '-i "${input}"'

	if cfg.strip_metadata {
		parts << '-map_metadata -1'
		parts << '-metadata comment=""'
		parts << '-metadata author=""'
		parts << '-metadata date=""'
		parts << '-fflags +bitexact'
		parts << '-flags:v +bitexact'
	}

	parts << '-vf "${filters}"'

	if cfg.force_8bit {
		parts << '-pix_fmt rgb24'
	}

	parts << '-color_primaries bt709'
	parts << '-color_trc iec61966-2-1'
	parts << '-colorspace bt709'

	ext := os.file_ext(output).to_lower()
	match ext {
		'.png' {
			parts << '-compression_level 6'
			parts << '-update 1'
		}
		'.jpg', '.jpeg' {
			parts << '-q:v ${(100 - cfg.quality) / 3 + 1}'
			parts << '-huffman optimal'
		}
		'.webp' {
			parts << '-quality ${cfg.quality}'
			parts << '-preset default'
		}
		'.bmp' {}
		else {}
	}

	parts << '"${output}"'
	return parts.join(' ')
}

fn build_fallback_cmd(cfg SanitizeConfig, input string, output string) string {
	mut filters := 'format=rgb24'
	if cfg.kill_subpixel {
		filters += ',gblur=sigma=${cfg.blur_sigma}'
		filters += ',unsharp=3:3:0.3:3:3:0.0'
	}
	if cfg.add_noise && cfg.noise_strength > 0 {
		filters += ',noise=alls=${cfg.noise_strength}:allf=t+u'
	}
	return 'ffmpeg -y -hide_banner -loglevel error -i "${input}" -map_metadata -1 -vf "${filters}" -pix_fmt rgb24 "${output}"'
}

fn strip_residual_metadata(path string, verbose bool) {
	ext := os.file_ext(path)
	tmp := '${temp_prefix}${rand.int_in_range(10000, 99999) or { 55555 }}${ext}'
	cmd := 'ffmpeg -y -hide_banner -loglevel error -i "${path}" -map_metadata -1 -fflags +bitexact -flags:v +bitexact -c copy "${tmp}"'
	r := os.execute(cmd)
	if r.exit_code == 0 && os.exists(tmp) {
		os.rm(path) or {}
		os.mv(tmp, path) or {}
		if verbose {
			println('  [i] Residual metadata stripped')
		}
	} else {
		os.rm(tmp) or {}
	}
}

fn batch_sanitize(mut cfg SanitizeConfig) {
	if cfg.batch_dir == '' {
		eprintln('[✗] No batch directory specified')
		return
	}
	if !os.is_dir(cfg.batch_dir) {
		eprintln('[✗] Not a directory: ${cfg.batch_dir}')
		return
	}

	image_exts := ['.png', '.jpg', '.jpeg', '.bmp', '.webp', '.tiff', '.tif']

	files := os.ls(cfg.batch_dir) or {
		eprintln('[✗] Cannot list directory')
		return
	}

	mut count := 0
	for f in files {
		ext := os.file_ext(f).to_lower()
		if ext in image_exts {
			full_path := os.join_path(cfg.batch_dir, f)
			base := f.trim_string_right(ext)
			out_path := os.join_path(cfg.batch_dir, '${base}_clean${ext}')
			cfg.input_path = full_path
			cfg.output_path = out_path
			sanitize_single(cfg) or {
				eprintln('  [✗] Failed: ${f}: ${err}')
				continue
			}
			count++
		}
	}
	println('\n[✓] Batch complete: ${count} images sanitized')
}

fn format_size(bytes u64) string {
	if bytes < 1024 {
		return '${bytes}B'
	} else if bytes < 1024 * 1024 {
		return '${f64(bytes) / 1024.0:.1f}KB'
	} else {
		return '${f64(bytes) / (1024.0 * 1024.0):.1f}MB'
	}
}
