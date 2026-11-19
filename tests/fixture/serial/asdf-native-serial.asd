;;; Copied to a temporary directory and loaded in child images by the
;;; stamp tests (issue #5): a :native-library between Lisp files.
(defsystem "asdf-native-serial"
  :defsystem-depends-on ("asdf-native")
  :depends-on ("cffi")
  :serial t
  :components ((:file "before")
               (:native-library "andemo")
               (:file "after")
               (:file "last")))
