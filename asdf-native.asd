(defsystem "asdf-native"
  :version "0.1.0"
  :description "ASDF component that loads a package's own native library by absolute path: env override, native/ (cl-repo overlay), lib/<os>-<arch>/ (checkout)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("cffi")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "native-library"))
  :in-order-to ((test-op (test-op "asdf-native/tests"))))

(defsystem "asdf-native/tests"
  :depends-on ("asdf-native" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "native-library-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
