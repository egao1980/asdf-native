;;; Loaded by the tests only (ASDF:LOAD-ASD), not part of the source registry.
(defsystem "asdf-native-fixture"
  :defsystem-depends-on ("asdf-native")
  :components ((:native-library "andemo")
               (:native-library "absent-lib")
               (:native-library "renamed"
                :names (:darwin ("librenamed.1.dylib" "librenamed.dylib")
                        :unix ("librenamed.so.1" "librenamed.so")
                        :windows ("renamed-1.dll"))
                :env "RENAMED_DIR")
               ;; Generated variants with an ABI version; Windows alone overridden.
               (:native-library "verdemo"
                :versions ("2")
                :names (:windows ("verdemo-2-x64.dll")))))
