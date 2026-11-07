# asdf-native

An ASDF component that loads a system's own native library at ASDF load, by
absolute path. Nothing to write but the `.asd`:

```lisp
(defsystem "image-backend-stb"
  :defsystem-depends-on ("asdf-native")
  :depends-on ("cffi" "image-protocol")
  :serial t
  :components ((:file "package")
               (:native-library "stb-cl")      ; libstb-cl.dylib / libstb-cl.so / stb-cl.dll
               (:file "backend")))
```

`(asdf:load-system "image-backend-stb")` then finds and loads the library. It
needs no init script, wrapper function or cl-repo at runtime.

## Where it looks

For a component named `stb-cl`, in this order:

1. `$STB_CL_NATIVE`, a directory to override with (`:env` renames the variable).
2. `<system>/native/`, the platform overlay a cl-repo install puts there.
3. `<system>/lib/<os>-<arch>/` (`darwin-arm64`, `linux-amd64`, …), libraries built in a checkout.

The first match is loaded by its truename, so a distro library with the same
soname can't take its place. Its directory goes onto
`cffi:*foreign-library-directories*`, so the libraries it depends on resolve
there too. `LD_LIBRARY_PATH` is never needed.

## Name variants

With no options, `(:native-library "foo")` tries the names below. `:versions`
puts the versioned names first, most specific first:

| OS | `(:native-library "foo" :versions ("3"))` tries |
| --- | --- |
| macOS | `libfoo.3.dylib`, `libfoo.dylib` |
| Linux / other Unix | `libfoo.so.3`, `libfoo.so` |
| Windows | `foo-3.dll`, `libfoo-3.dll`, `foo.dll`, `libfoo.dll` (MSVC and MinGW naming) |

Several versions are tried in the order given: `:versions ("1" "0")`.

`:names` replaces the generated names: a plain list applies to every OS, and a
plist applies only to the OSes it names (`:unix` covers macOS and Linux):

```lisp
(:native-library "crypto"                   ; several components load in order
 :versions ("3")                            ; libcrypto.3.dylib, libcrypto.so.3 …
 :names (:windows ("libcrypto-3-x64.dll"))  ; OpenSSL's own Windows name
 :env "CL_STACK_SSL_NATIVE")
(:native-library "ssl" :versions ("3") :names (:windows ("libssl-3-x64.dll")))

(:native-library "uv" :versions ("1") :system t)   ; not found → dlopen libuv.so.1 &c.
```

`file-name-variants` shows the names for any OS:
`(asdf-native:file-name-variants "uv" :versions '("1") :os :windows)`.

## Optional libraries and extra directories

```lisp
(:native-library "ggml-cuda" :optional t)   ; missing → warning, system loads without it
(:native-library "llama"
 :directories ("lib/{pair}-{env:LLAMA_CPP_FLAVOR}/"   ; skipped when the variable is unset
               ""))                                    ; the system root (a make build)
```

`:fallback-directories` take the same templates but are searched after
`native/` and `lib/<os>-<arch>/`, so a package manager's directory never takes
priority over the overlay:
`(:native-library "icuuc" :versions ("79") :fallback-directories ("/opt/homebrew/opt/icu4c/lib/"))`.

`:directories` entries come after the env override and before `native/`. They
are relative to the system root unless absolute, and the templates are
`{pair}`, `{os}`, `{arch}` and `{env:VAR}`. An optional library that is missing
signals the warning `native-library-missing` and leaves its loaded path NIL.
`(asdf-native:library-loaded-path "llama-cpp" "llama")` lets a system's own
`*-available-p` check which libraries were loaded.

## When it's missing

Loading signals `asdf-native:native-library-not-found`, whose report lists
every path tried. Its restarts are `use-value`, which loads a pathname you
supply, and `continue`, which skips the library. Checks that run after the
load, such as an ABI version check, belong in the system's own code after
the component.

## API

- `find-native-library`, `load-native-library`, `search-directories`
- `native-library-names`, `file-name-variants`, `native-library-loaded-path`, `host-pair`
