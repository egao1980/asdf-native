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

## Options

```lisp
(:native-library "crypto"                 ; several components load in order:
 :names (:darwin ("libcrypto.3.dylib" "libcrypto.dylib")   ; per OS; :unix covers
         :unix ("libcrypto.so.3" "libcrypto.so")           ; darwin and linux
         :windows ("libcrypto-3-x64.dll"))
 :env "CL_STACK_SSL_NATIVE"
 :system t)                               ; not found → dlopen the first name
(:native-library "ssl" :names (...))      ; after crypto
```

The default names are `lib<name>.dylib`, `<name>.dll` and `lib<name>.so`.

## When it's missing

Loading signals `asdf-native:native-library-not-found`, whose report lists
every path tried. Its restarts are `use-value`, which loads a pathname you
supply, and `continue`, which skips the library. Checks that run after the
load, such as an ABI version check, belong in the system's own code after
the component.

## API

- `find-native-library`, `load-native-library`, `search-directories`
- `native-library-loaded-path`, `host-pair`, `default-file-names`
