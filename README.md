# parse.nvim

Minimal Competitive Companion -> Neovim plumbing for my competitive-programming setup.

It keeps the useful part of the old Python receiver scripts:

1. receive a Competitive Companion payload;
2. route it through the parser I selected;
3. create the C++ file if it does not exist;
4. create/update the directory `CMakeLists.txt` like the original `gen.py`;
5. write/refresh the sample `.in` / `.out` files;
6. open the source file in Neovim.

There is no compiler runner, test UI, contest scaffolding, or compile database generation.

## Routing: manual by default

`parse.nvim` does **not** guess the problem type by default.

Before sending a problem, choose the old script behavior you want:

```vim
:ParseUse cf
:ParseUse atcoder
:ParseUse qoj
:ParseUse cses
:ParseUse usaco
:ParseUse 603
:ParseUse camp
```

The choice stays active until you change it. Run `:ParseUse` with no argument for a picker.

To opt into judge detection:

```vim
:ParseUse auto
```

Auto mode uses the Competitive Companion URL/group/source when it can. If it cannot identify a handler, it falls back to the same picker containing all custom handlers instead of silently using a generic parser.

Return to manual/picker mode with:

```vim
:ParseUse manual
```

## Included handlers

These correspond to the original Flask receiver scripts:

| Handler | Original script | Behavior retained |
| --- | --- | --- |
| `cf` | `cf.py` | Codeforces problem/round naming |
| `atcoder` | `atcoder.py` | ABC/ARC/AGC/AHC folder naming; prompts for unknown contest folder |
| `qoj` | `qoj.py` | QOJ id/title naming |
| `codechef` | `codechef.py` | Original CodeChef receiver path/naming behavior |
| `cses` | `cses.py` | Prompts for topic; Roman numeral conversion |
| `usaco` | `usaco.py` | `prev/<division>/<contest>` layout and USACO template |
| `uva` | `uva.py` | UVA filename cleanup and flat source layout |
| `oly` | `oly.py` | IOI/oj.uz payload routing and inline `01.in`, `01.out`, ... samples |
| `603` | `603.py` | Prompts for week + name; `XC_603_2026` |
| `603p` | `603p.py` | Prompts for week + name; `XC_603P_2026` |
| `camp` | `camp.py` | Prompts for name + day; `XC_603SummerCamp2026` |
| `hw` | `hw.py` | Prompts for week + name; `XC_602_2026_Winter` |
| `hw_old` | `hw_old.py` | Prompts for week + name; `XC_602_2025` |

`data.py` is intentionally not a handler because it only printed payloads and did not create a source file/test data. The non-listener utility/debug scripts are also outside this plugin's scope.

## Requirements

- Neovim >= 0.11.2
- Competitive Companion

No Python or Flask dependency is required.

## LazyVim

```lua
-- ~/.config/nvim/lua/plugins/parse.lua
return {
  {
    "brendonwang/parse.nvim",
    event = "VeryLazy",
    opts = {
      base_dir = vim.env.BASE_DIR,
      auto_start = true,
      open_on_receive = true,
      parser = nil, -- manual by default
    },
  },
}
```

Point Competitive Companion at:

```text
http://127.0.0.1:10043/
```

If you always want one receiver, you can set it in LazyVim instead of calling `:ParseUse`:

```lua
opts = {
  parser = "cf",
}
```

Or explicitly opt into automatic detection:

```lua
opts = {
  parser = "auto",
}
```

## Paths

By default paths remain based on `BASE_DIR`:

```lua
roots = {
  codeforces = "contests/codeforce",
  atcoder = "contests/AtCoder",
  qoj = "contests/QOJ",
  codechef = "contests/codeforce", -- matches original codechef.py
  cses = "contests/CSES",
  uva = "contests/uva",
  usaco = "usaco",
  olympiads = "olympiads",
  classes = "USACO_Classes",
}
```

Normal handlers write samples using the old `gen.py` layout:

```text
<root>/data/<cur>/<problem>/1.in
<root>/data/<cur>/<problem>/1.out
<root>/data/<cur>/<problem>/2.in
<root>/data/<cur>/<problem>/2.out
```

`uva` naturally becomes `<root>/data/<problem>/...` because it has no `cur` folder. `oly` follows the old olympiad script and puts samples next to the source as `01.in`, `01.out`, etc.

Existing source files are never overwritten. Re-sending a problem refreshes only numeric sample files.

## CMakeLists.txt

Generation follows the original `gen.py` behavior. For a handler whose `cur` is `Round_123`, the source directory contains:

```cmake
cmake_minimum_required(VERSION 3.27)
project(Round_123)

set(CMAKE_CXX_STANDARD 17)

add_executable(Round_123a a.cpp)
add_executable(Round_123b b.cpp)
```

The target prefix is exactly the old `cur.replace("/", "_")` convention. Existing `CMakeLists.txt` files are preserved and new `add_executable(...)` entries are appended only when missing, so receiving the same problem again does not create duplicate targets.

## Templates

Configure templates directly if wanted:

```lua
opts = {
  templates = {
    cf = "/path/to/template_cf.cpp",
    usaco = "/path/to/template_usaco.cpp",
  },
}
```

Otherwise the plugin first checks:

```text
<base_dir>/algo/library/template_cf.cpp
<base_dir>/algo/library/template_usaco.cpp
```

and then uses its bundled fallback templates.

## Commands

```text
:ParseUse [manual|auto|cf|atcoder|qoj|codechef|cses|usaco|uva|oly|603|603p|camp|hw|hw_old]
:ParseStart
:ParseStop
:ParseStatus
```
