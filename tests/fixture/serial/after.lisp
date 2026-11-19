(in-package #:asdf-native-serial)

(cffi:defcfun ("andemo_answer" %answer) :int (x :int))
