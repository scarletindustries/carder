#!/usr/bin/env bash
# porffor-codegen-fixes.sh — apply our Porffor codegen/assemble bug fixes to a compiler directory.
#
# These are genuine Porffor self-compile bugs (see FINDINGS.md). They must be applied to BOTH Porffor
# copies (FINDINGS §7b): the vendored compiler (-> porffor.wasm, via scripts/apply-patches.sh) AND the
# npx build tool (-> compiles the bundle, via scripts/patch-build-tool.sh). This script is the single
# source of truth for those edits so the two stay in lock-step.
#
# Fixes:
#   1. makeString('') returns null pointer 0 -> reads garbage at address 0 in large programs
#      (FINDINGS §6). Point empty strings at a reserved zero slot instead.
#   2. func lut region was 2 pages; bytesPerFuncLut = floor(pageSize*2/nIndirect) drops below the
#      7-byte minimum entry once there are many indirect funcs, corrupting the constr flag ->
#      function .prototype undefined (FINDINGS §7). Grow to 16 pages.
#   3. func lut data segment offset is resolved via pages.allocs (string-intern table); when
#      self-hosting, the bundle contains the string literal '#func lut', so its interned offset
#      SHADOWS the func lut page offset -> the lut is written to the wrong place and every function's
#      .name/.length/.prototype reads 0 (FINDINGS §7). Pin the lut to its true page offset.
#
# Usage: porffor-codegen-fixes.sh <compiler-dir>   (dir containing compiler/codegen.js + compiler/assemble.js)
# Idempotent. We DO NOT contact upstream Porffor (out-of-scope experiment); fixes live here.
set -uo pipefail
DIR="${1:?usage: porffor-codegen-fixes.sh <compiler-dir>}"
CG="$DIR/compiler/codegen.js"
AS="$DIR/compiler/assemble.js"
[ -f "$CG" ] || { echo "[codegen-fixes] no codegen.js in $DIR"; exit 1; }
[ -f "$AS" ] || { echo "[codegen-fixes] no assemble.js in $DIR"; exit 1; }

python3 - "$CG" "$AS" <<'PY'
import sys
cg_path, as_path = sys.argv[1], sys.argv[2]
cg = open(cg_path).read()
asm = open(as_path).read()
changed = []

# 1. makeString empty string -> reserved zero slot
old = 'if (str.length === 0) return [ number(0) ];'
new = "if (str.length === 0) return [ number(allocStr(scope, '', bytestring)) ]; // [2core] empty string -> reserved zero slot, not null ptr 0 (FINDINGS §6)"
if '[2core] empty string' not in cg and old in cg:
    cg = cg.replace(old, new, 1); changed.append('makeString')

# 2a. func lut region: 2 pages -> 16 pages (allocLargePage)
old = "    const _ = allocPage(scope, name);\n    allocPage(scope, name + '#2');\n\n    return _;"
new = ("    // [2core] func lut needs bytesPerFuncLut >= 7 (2 length + 1 flags + 4 nameLen); 2 pages\n"
       "    // forced it below 7 for many indirect funcs, corrupting the constr flag (FINDINGS §7).\n"
       "    const _ = allocPage(scope, name);\n"
       "    for (let _i = 2; _i <= 16; _i++) allocPage(scope, name + '#' + _i);\n\n    return _;")
if '_i <= 16' not in cg and old in cg:
    cg = cg.replace(old, new, 1); changed.append('allocLargePage')

# 2b. bytesPerFuncLut budget: pageSize*2 -> pageSize*16 (must match allocLargePage)
old = 'Math.min(Math.floor((pageSize * 2) / indirectFuncs.length)'
new = 'Math.min(Math.floor((pageSize * 16) / indirectFuncs.length)' # [2core] match 16 func-lut pages
if 'pageSize * 16) / indirectFuncs.length' not in cg and old in cg:
    cg = cg.replace(old, new, 1); changed.append('bytesPerFuncLut')

open(cg_path, 'w').write(cg)

# 3a. func lut data push: pin to page offset (assemble.js)
old = "    data.push({\n      page: '#func lut',\n      bytes\n    });"
new = ("    // [2core] pin the func lut to its PAGE offset; a string literal '#func lut' in the compiled\n"
       "    // program (self-hosting) interns into pages.allocs and would otherwise shadow it (FINDINGS §7).\n"
       "    data.push({\n      page: '#func lut',\n      offset: pages.get('#func lut') * pageSize,\n      bytes\n    });")
if "offset: pages.get('#func lut')" not in asm and old in asm:
    asm = asm.replace(old, new, 1); changed.append('funcLutPush')

# 3b. data section size pre-count: honour explicit offset
old = 'acc + (x.page != null ? (3 + signedLEB128_length(pages.allocs.get(x.page) ?? (pages.get(x.page) * pageSize))) : 1)'
new = 'acc + (x.page != null ? (3 + signedLEB128_length(x.offset ?? (pages.allocs.get(x.page) ?? (pages.get(x.page) * pageSize)))) : 1)'
if 'signedLEB128_length(x.offset ??' not in asm and old in asm:
    asm = asm.replace(old, new, 1); changed.append('dataSizeCalc')

# 3c. data emission: honour explicit offset
old = 'let offset = pages.allocs.get(x.page) ?? (pages.get(x.page) * pageSize);'
new = 'let offset = x.offset ?? (pages.allocs.get(x.page) ?? (pages.get(x.page) * pageSize)); // [2core] explicit page offset beats string-intern collision (FINDINGS §7)'
if 'let offset = x.offset ??' not in asm and old in asm:
    asm = asm.replace(old, new, 1); changed.append('dataEmit')

open(as_path, 'w').write(asm)
print('[codegen-fixes] applied: ' + (', '.join(changed) if changed else '(all already present)') + ' -> ' + cg_path.rsplit('/',3)[0])
PY
