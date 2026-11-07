(in-package #:asdf-native/tests)

(defparameter *fixture-dir*
  (asdf:system-relative-pathname "asdf-native" "tests/fixture/"))

(defun fixture-system ()
  (or (asdf:find-system "asdf-native-fixture" nil)
      (progn (asdf:load-asd (merge-pathnames "asdf-native-fixture.asd" *fixture-dir*))
             (asdf:find-system "asdf-native-fixture"))))

(defun lib (name) (asdf:find-component (fixture-system) name))

(defmacro with-env ((var value) &body body)
  (let ((old (gensym)))
    `(let ((,old (uiop:getenv ,var)))
       (setf (uiop:getenv ,var) ,value)
       (unwind-protect (progn ,@body)
         (setf (uiop:getenv ,var) (or ,old ""))))))

(deftest component-type
  (ok (typep (lib "andemo") 'an:native-library) ":native-library resolves through ASDF")
  (ok (null (asdf:input-files (asdf:make-operation 'asdf:compile-op) (lib "andemo")))
      "no input files"))

(deftest file-names
  (let ((names (an:default-file-names "foo-cl")))
    (ok (equal names
               #+darwin '("libfoo-cl.dylib") #+windows '("foo-cl.dll")
               #-(or darwin windows) '("libfoo-cl.so"))))
  (ok (equal (an:native-library-names (lib "renamed"))
             #+darwin '("librenamed.1.dylib" "librenamed.dylib")
             #+windows '("renamed-1.dll")
             #-(or darwin windows) '("librenamed.so.1" "librenamed.so"))
      "per-OS plist, :unix covering darwin and linux when no exact key"))

(deftest env-names
  (ok (string= (an:native-library-env (lib "andemo")) "ANDEMO_NATIVE"))
  (ok (string= (an:native-library-env (lib "absent-lib")) "ABSENT_LIB_NATIVE"))
  (ok (string= (an:native-library-env (lib "renamed")) "RENAMED_DIR") "explicit :env"))

(deftest search-order
  (let ((root (asdf:system-source-directory (fixture-system))))
    (with-env ("ANDEMO_NATIVE" "/tmp/andemo-override")
      (ok (equal (mapcar #'namestring (an:search-directories (lib "andemo")))
                 (list "/tmp/andemo-override/"
                       (namestring (merge-pathnames "native/" root))
                       (namestring (merge-pathnames (format nil "lib/~A/" (an:host-pair)) root))))
          "env, native/, lib/<os>-<arch>/"))
    (with-env ("ANDEMO_NATIVE" "")
      (ok (= 2 (length (an:search-directories (lib "andemo")))) "empty env is ignored"))))

(deftest not-found
  (let ((c (lib "absent-lib")))
    (ok (null (an:find-native-library c)))
    (ok (signals (an:load-native-library c) 'an:native-library-not-found))
    (let ((condition (handler-case (an:load-native-library c)
                       (an:native-library-not-found (e) e))))
      (ok (= 2 (length (an:native-library-not-found-tried condition))) "both directories tried")
      (ok (search "ABSENT_LIB_NATIVE" (princ-to-string condition)) "report names the override"))
    (ok (null (handler-bind ((an:native-library-not-found
                               (lambda (e) (declare (ignore e)) (invoke-restart 'continue))))
                (an:load-native-library c)))
        "CONTINUE skips")))

(defun compiler ()
  (find-if (lambda (cc) (ignore-errors (uiop:run-program (list cc "--version")) t))
           '("cc" "gcc" "clang")))

(deftest load-real-library
  (let ((cc (compiler)))
    (if (null cc)
        (skip "no C compiler on PATH")
        (let* ((dir (uiop:ensure-directory-pathname
                     (merge-pathnames (format nil "asdf-native-~36R/" (random (expt 36 8)))
                                      (uiop:temporary-directory))))
               (name (first (an:default-file-names "andemo")))
               (out (merge-pathnames name dir)))
          (ensure-directories-exist dir)
          (uiop:run-program (list cc "-shared" "-fPIC" "-o" (uiop:native-namestring out)
                                  (uiop:native-namestring (merge-pathnames "andemo.c" *fixture-dir*)))
                            :error-output :string)
          (unwind-protect
               (with-env ("ANDEMO_NATIVE" (uiop:native-namestring dir))
                 (let ((c (lib "andemo")))
                   (ok (equal (an:find-native-library c) (truename out)) "found through the env dir")
                   (an:load-native-library c)
                   (ok (equal (an:native-library-loaded-path c) (truename out)) "loaded by absolute path")
                   (ok (member (truename dir) cffi:*foreign-library-directories* :test #'equal)
                       "directory pushed for its dependencies")
                   (ok (= 43 (cffi:foreign-funcall "andemo_answer" :int 1 :int)) "symbol callable")
                   (ok (asdf:operation-done-p (asdf:make-operation 'asdf:load-op) c) "done once loaded")))
            (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))))
