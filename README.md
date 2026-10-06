# parse.nvim

Minimal Competitive Companion -> Neovim plumbing for my competitive-programming setup.

It keeps the useful part of the old Python receiver scripts:

1. receive a Competitive Companion payload;
2. route it through the parser I selected;
3. create the C++ file if it does not exist;
4. create/update the directory `CMakeLists.txt` like the original `gen.py`;
5. write Competitive Companion samples using the original `gen.py` data layout;
6. configure CMake/`compile_commands.json` for clangd;
7. open the source file in Neovim.

On first import, testcase payloads are written as numbered `.in` / `.out` files
under `<root>/data/<cur>/<problem>/`. parse.nvim does not run or display those
tests; that remains the job of tools such as cph.nvim. Re-sending an existing
problem leaves its source and testcase files untouched.

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

Auto mode checks registered custom handlers first, then built-in judge detection. If nothing matches, it falls back to the parser picker.

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
| `oly` | `oly.py` | IOI/oj.uz problem naming and directory routing |
| `603` | `603.py` | Prompts for week + name; `XC_603_2026` |
| `603p` | `603p.py` | Prompts for week + name; `XC_603P_2026` |
| `camp` | `camp.py` | Prompts for name + day; `XC_603SummerCamp2026` |
| `hw` | `hw.py` | Prompts for week + name; `XC_602_2026_Winter` |
| `hw_old` | `hw_old.py` | Prompts for week + name; `XC_602_2025` |

## Extensible handlers

Handlers can be added or overridden from setup:

```lua
opts = {
  handlers = {
    luogu = {
      label = "Luogu",
      priority = 50,
      detect = function(data)
        return (data.url or ""):find("luogu.com.cn", 1, true) ~= nil
      end,
      parse = function(data, done)
        done({
          handler = "luogu",
          judge = "luogu",
          root = "/path/to/luogu",
          cur = data.group or "misc",
          name = data.name or "problem",
          template = "cf",
        })
      end,
    },
  },
}
```

A built-in can be overridden by registering the same name, or disabled with:

```lua
handlers = {
  codechef = false,
}
```

Runtime registration is also supported:

```lua
require("parse").register_handler("luogu", definition)
require("parse").unregister_handler("luogu")
```

## Requirements

- Neovim >= 0.11.2
- Competitive Companion
- CMake is optional; source and sample generation still work without it

No Python or Flask dependency is required.

## LazyVim

```lua
return {
  {
    "brendonwang/parse.nvim",
    event = "VeryLazy",
    opts = {
      base_dir = vim.env.BASE_DIR,
      auto_start = true,
      open_on_receive = true,
      parser = nil,
    },
  },
}
```

Point Competitive Companion at:

```text
http://127.0.0.1:10043/
```

## Paths

By default paths remain based on `BASE_DIR`:

```lua
roots = {
  codeforces = "contests/codeforce",
  atcoder = "contests/AtCoder",
  qoj = "contests/QOJ",
  codechef = "contests/codeforce",
  cses = "contests/CSES",
  uva = "contests/uva",
  usaco = "usaco",
  olympiads = "olympiads",
  classes = "USACO_Classes",
}
```

Incoming samples use the same layout as the original Python `gen.py`:

```text
<root>/data/<cur>/<problem>/1.in
<root>/data/<cur>/<problem>/1.out
<root>/data/<cur>/<problem>/2.in
<root>/data/<cur>/<problem>/2.out
```

Sample files are written when the source is first created. Existing source files
are never overwritten, and re-sending a problem repairs missing CMake targets
without changing existing source or testcase files.

## CMake and clangd

The defaults preserve the original generator while adding clangd support:

```lua
cmake = {
  minimum_version = "3.27",
  cxx_standard = 17,
  export_compile_commands = true,
  configure = true,
  build_dir = "out",
  configure_args = {}, -- e.g. { "-DCMAKE_CXX_COMPILER=/path/to/g++" }
  link_compile_commands = true,
  target_name_formatter = nil,
}
```

Generated projects look like:

```cmake
cmake_minimum_required(VERSION 3.27)
project(Round_123)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(Round_123a a.cpp)
```

Each generated problem directory keeps its own `CMakeLists.txt`. The handler root `CMakeLists.txt` points at the current problem directory with `add_subdirectory(...)`; parse.nvim replaces the most recent active `add_subdirectory(...)` entry instead of appending one on every import. If CMake is installed, the plugin configures that root project into `<root>/out` and publishes compile commands to the configured base directory for clangd.

CMake target names are sanitized automatically. You can customize them before sanitization:

```lua
cmake = {
  target_name_formatter = function(default_name, spec)
    return spec.name
  end,
}
```

## New file from a template

Create and open a fresh C++ source in the current buffer's directory (or the
working directory when there is no named buffer):

```vim
:ParseNew cf a
:ParseNew usaco gates.cpp
:ParseNew cf
:ParseNew
```

The `.cpp` extension is added if omitted. With no filename, a prompt opens;
without an explicit template, the active handler selects the template (`usaco`
for USACO, otherwise `cf`). For example, `:ParseNew a` uses that default.
Cancelling the prompt changes nothing. Existing files are refused, never replaced.
Use a plain filename, not a directory path.

This uses the same configured/personal CF and USACO templates described below,
and adds the file to CMake through the existing project-generation workflow.

## Contest scaffolding

`:ParseContest` creates source files and CMake targets in the current buffer's directory. It uses the active handler's template convention (`usaco` gets the USACO template; everything else defaults to the CF template).

Examples:

```vim
:ParseContest a-f
:ParseContest 10
:ParseContest first 10
:ParseContest first:10
:ParseContest a b c d e
:ParseContest a,c,e-g
```

`10` means the first ten alphabetic problem names: `a` through `j`. Counts beyond 26 continue as `aa`, `ab`, etc.

## Payload inspection

The most recently received Competitive Companion payload is retained in memory:

```vim
:ParseLast
```

It opens in a scratch buffer. If `jq` is installed it is displayed as formatted JSON; otherwise Neovim's structured representation is used.

## Templates

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
:ParseUse [manual|auto|<handler>]
:ParseStart
:ParseStop
:ParseStatus
:ParseLast
:ParseContest <names|range|count>
:ParseNew [cf|usaco] [name]
```

## Tests

The repository contains headless regression tests for built-in routing, handler overrides, CMake generation, target sanitization, duplicate prevention, contest-name expansion, testcase data generation, and new-file template selection:

```sh
nvim --headless -u NONE -l tests/run.lua
```

The same suite runs in GitHub Actions.
