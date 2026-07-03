module main

import os
import term
import crypto.sha3

const zw_characters = ['\u200B', '\u200C', '\u200D', '\u2060']
const homoglyphs = {
	'a': 'а'
	'c': 'с'
	'e': 'е'
	'o': 'о'
	'p': 'р'
	'y': 'у'
}

struct SecurePRNG {
mut:
	seed    []u8
	counter u64
	buffer  []u8
	idx     int
}

struct LoopState {
	start_ip int
	count    int
mut:
	current int
}

struct AsdInterpreter {
mut:
	lines      []string
	ip         int
	variables  map[string]string
	buffer     string
	prng       SecurePRNG
	loop_stack []LoopState
	if_stack   []bool
	skip_depth int
}

fn (mut rng SecurePRNG) next_u8() u8 {
	if rng.idx >= rng.buffer.len {
		mut state := []u8{cap: rng.seed.len + 8}
		for b in rng.seed {
			state << b
		}
		mut temp := []u8{}
		write_u64(mut temp, rng.counter)
		for b in temp {
			state << b
		}
		rng.counter++
		rng.buffer = sha3.sum512(state).clone()
		rng.idx = 0
	}
	val := rng.buffer[rng.idx]
	rng.idx++
	return val
}

fn (mut rng SecurePRNG) next_u32() u32 {
	b0 := rng.next_u8()
	b1 := rng.next_u8()
	b2 := rng.next_u8()
	b3 := rng.next_u8()
	return (u32(b0) << 24) | (u32(b1) << 16) | (u32(b2) << 8) | b3
}

fn (mut rng SecurePRNG) intn(n int) int {
	if n <= 0 {
		return 0
	}
	limit := u32(-n) % u32(n)
	for {
		r := rng.next_u32()
		if r >= limit {
			return int(r % u32(n))
		}
	}
	return 0
}

fn new_secure_prng_from_string(seed_str string) SecurePRNG {
	hashed := sha3.sum512(seed_str.bytes())
	return SecurePRNG{
		seed:    hashed.clone()
		counter: 0
		buffer:  []u8{}
		idx:     0
	}
}

fn write_u64(mut b []u8, val u64) {
	b << u8(val >> 56)
	b << u8(val >> 48)
	b << u8(val >> 40)
	b << u8(val >> 32)
	b << u8(val >> 24)
	b << u8(val >> 16)
	b << u8(val >> 8)
	b << u8(val)
}

fn get_noise_chars(custom_str string) []rune {
	if custom_str != '' {
		mut runes := []rune{}
		for r in custom_str.replace(',', '').trim_space().runes() {
			runes << r
		}
		if runes.len > 0 {
			return runes
		}
	}
	noise_str := '*~_•°†‡▲▼◆◇■□◀▶♠♥♦♣★☆✦✧✪✿'
	return noise_str.runes()
}

fn (mut inter AsdInterpreter) execute() ! {
	for inter.ip < inter.lines.len {
		line := inter.lines[inter.ip].trim_space()
		if line == '' || line.starts_with('#') {
			inter.ip++
			continue
		}

		mut processed_line := line
		for k, v in inter.variables {
			processed_line = processed_line.replace('$' + k, v)
		}

		parts := processed_line.split(' ')
		if parts.len == 0 || parts[0] == '' {
			inter.ip++
			continue
		}
		op := parts[0]

		if inter.skip_depth > 0 {
			if op in ['if_rand', 'if_eq'] {
				inter.skip_depth++
			} else if op == 'endif' {
				inter.skip_depth--
				if inter.if_stack.len > 0 {
					inter.if_stack.pop()
				}
			} else if op == 'else' && inter.skip_depth == 1 {
				if inter.if_stack.len > 0 {
					last_cond := inter.if_stack.last()
					if !last_cond {
						inter.skip_depth = 0
					}
				}
			}
			inter.ip++
			continue
		}

		match op {
			'set' {
				if parts.len < 3 {
					return error('Line ${inter.ip + 1}: "set" command requires variable name and value.')
				}
				val := processed_line.all_after(parts[1]).trim_space().trim('"')
				inter.variables[parts[1]] = val
			}
			'map' {
				content := processed_line.all_after('map').trim_space()
				sub_parts := content.split(':')
				if sub_parts.len < 2 {
					return error('Line ${inter.ip + 1}: "map" command requires target and options separated by ":"')
				}
				key := sub_parts[0].trim_space()
				mut options := []string{}
				for p in sub_parts[1..] {
					options << p.trim_space()
				}
				if inter.buffer.contains(key) {
					mut new_buffer := []rune{}
					runes := inter.buffer.runes()
					mut i := 0
					for i < runes.len {
						mut match_found := false
						if i + key.runes().len <= runes.len {
							sub := runes[i..i + key.runes().len].string()
							if sub == key {
								opt := options[inter.prng.intn(options.len)]
								for r in opt.runes() {
									new_buffer << r
								}
								i += key.runes().len
								match_found = true
							}
						}
						if !match_found {
							new_buffer << runes[i]
							i++
						}
					}
					inter.buffer = new_buffer.string()
				}
			}
			'zwsp' {
				rate := if parts.len >= 2 { parts[1].int() } else { 30 }
				if rate < 0 || rate > 100 {
					return error('Line ${inter.ip + 1}: "zwsp" rate must be between 0 and 100.')
				}
				mut result := []rune{}
				for r in inter.buffer.runes() {
					result << r
					if inter.prng.intn(100) < rate {
						zw := zw_characters[inter.prng.intn(zw_characters.len)]
						result << zw.runes()[0]
					}
				}
				inter.buffer = result.string()
			}
			'noise' {
				rate := if parts.len >= 2 { parts[1].int() } else { 10 }
				if rate < 0 || rate > 100 {
					return error('Line ${inter.ip + 1}: "noise" rate must be between 0 and 100.')
				}
				mut noise_pool := get_noise_chars('')
				if parts.len >= 3 {
					noise_pool = get_noise_chars(parts[2])
				}
				mut result := []rune{}
				for r in inter.buffer.runes() {
					result << r
					if inter.prng.intn(100) < rate {
						result << noise_pool[inter.prng.intn(noise_pool.len)]
					}
				}
				inter.buffer = result.string()
			}
			'homoglyph' {
				mut result := []rune{}
				for r in inter.buffer.runes() {
					r_str := r.str()
					if r_str in homoglyphs {
						result << homoglyphs[r_str].runes()[0]
					} else {
						result << r
					}
				}
				inter.buffer = result.string()
			}
			'append' {
				val := processed_line.all_after('append').trim_space().trim('"')
				inter.buffer += val
			}
			'prepend' {
				val := processed_line.all_after('prepend').trim_space().trim('"')
				inter.buffer = val + inter.buffer
			}
			'loop' {
				count := if parts.len >= 2 { parts[1].int() } else { 1 }
				if count <= 0 {
					return error('Line ${inter.ip + 1}: "loop" count must be a positive integer.')
				}
				inter.loop_stack << LoopState{
					start_ip: inter.ip
					count:    count
					current:  0
				}
			}
			'endloop' {
				if inter.loop_stack.len == 0 {
					return error('Line ${inter.ip + 1}: Found "endloop" without a matching "loop".')
				}
				mut loop_state := inter.loop_stack.last()
				loop_state.current++
				if loop_state.current < loop_state.count {
					inter.loop_stack[inter.loop_stack.len - 1] = loop_state
					inter.ip = loop_state.start_ip
				} else {
					inter.loop_stack.pop()
				}
			}
			'if_rand' {
				rate := if parts.len >= 2 { parts[1].int() } else { 50 }
				if rate < 0 || rate > 100 {
					return error('Line ${inter.ip + 1}: "if_rand" rate must be between 0 and 100.')
				}
				condition := inter.prng.intn(100) < rate
				inter.if_stack << condition
				if !condition {
					inter.skip_depth = 1
				}
			}
			'if_eq' {
				if parts.len < 3 {
					return error('Line ${inter.ip + 1}: "if_eq" requires two values to compare.')
				}
				condition := parts[1] == parts[2]
				inter.if_stack << condition
				if !condition {
					inter.skip_depth = 1
				}
			}
			'else' {
				if inter.if_stack.len == 0 {
					return error('Line ${inter.ip + 1}: Found "else" without a matching "if" condition.')
				}
				last_cond := inter.if_stack.last()
				if last_cond {
					inter.skip_depth = 1
				} else {
					inter.skip_depth = 0
				}
			}
			'endif' {
				if inter.if_stack.len == 0 {
					return error('Line ${inter.ip + 1}: Found "endif" without a matching "if" condition.')
				}
				inter.if_stack.pop()
				inter.skip_depth = 0
			}
			'print' {
				println(inter.buffer)
			}
			else {
				return error('Line ${inter.ip + 1}: Unknown command "${op}".')
			}
		}

		inter.ip++
	}

	if inter.loop_stack.len > 0 {
		return error('Syntax Error: Missing "endloop" for a loop block.')
	}
	if inter.if_stack.len > 0 {
		return error('Syntax Error: Missing "endif" for a conditional block.')
	}
}

fn main() {
	run() or {
		eprintln(term.red('Error: ${err.msg()}'))
		exit(1)
	}
}

fn run() ! {
	args := os.args
	if args.len < 2 || '-h' in args || '--help' in args {
		println('ASID - Advanced Scraper Interference & Disruption')
		println('Usage:')
		println('  asid --script <file.asd> --text <input_text> [--seed <value>]')
		println('  asid --script <file.asd> --file <input_file.txt> [--seed <value>]')
		return
	}

	mut script_path := ''
	mut text_input := ''
	mut file_path := ''
	mut seed_val := '1'

	for i := 1; i < args.len; i++ {
		match args[i] {
			'-p', '--script' {
				if i + 1 < args.len {
					script_path = args[i + 1]
					i++
				}
			}
			'-t', '--text' {
				if i + 1 < args.len {
					text_input = args[i + 1]
					i++
				}
			}
			'-f', '--file' {
				if i + 1 < args.len {
					file_path = args[i + 1]
					i++
				}
			}
			'-s', '--seed' {
				if i + 1 < args.len {
					seed_val = args[i + 1]
					i++
				}
			}
			else {}
		}
	}

	if script_path == '' {
		return error('--script parameter is required.')
	}

	if !os.exists(script_path) {
		return error('Script file not found: "${script_path}"')
	}
	if os.is_dir(script_path) {
		return error('"${script_path}" is a directory, not an .asd script file.')
	}

	if text_input != '' && file_path != '' {
		return error('Please specify either --text or --file, not both.')
	}

	mut final_input := text_input

	if file_path != '' {
		if !os.exists(file_path) {
			return error('Input text file not found: "${file_path}"')
		}
		if os.is_dir(file_path) {
			return error('"${file_path}" is a directory, not a valid text file.')
		}
		final_input = os.read_file(file_path) or {
			return error('Failed to read input file: ${err}')
		}
	}

	lines := os.read_lines(script_path) or { return error('Failed to read script file: ${err}') }

	mut inter := AsdInterpreter{
		lines:      lines
		ip:         0
		variables:  map[string]string{}
		buffer:     final_input
		prng:       new_secure_prng_from_string(seed_val)
		loop_stack: []LoopState{}
		if_stack:   []bool{}
		skip_depth: 0
	}

	inter.variables['buffer'] = final_input
	inter.execute()!
}
