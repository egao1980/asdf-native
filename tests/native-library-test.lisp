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
               #+darwin '("libfoo-cl.dylib") #+windows '("foo-cl.dll" "libfoo-cl.dll")
               #-(or darwin windows) '("libfoo-cl.so"))))
  (ok (equal (an:native-library-names (lib "renamed"))
             #+darwin '("librenamed.1.dylib" "librenamed.dylib")
             #+windows '("renamed-1.dll")
             #-(or darwin windows) '("librenamed.so.1" "librenamed.so"))
      "per-OS plist, :unix covering darwin and linux when no exact key"))

(deftest-parametrize file-name-variants
    ((os versions expected)
     (:darwin  nil        '("libfoo.dylib"))
     (:linux   nil        '("libfoo.so"))
     (:windows nil        '("foo.dll" "libfoo.dll"))
     (:darwin  '("3")     '("libfoo.3.dylib" "libfoo.dylib"))
     (:linux   '("3")     '("libfoo.so.3" "libfoo.so"))
     (:unix    '("3")     '("libfoo.so.3" "libfoo.so"))
     (:windows '("3")     '("foo-3.dll" "libfoo-3.dll" "foo.dll" "libfoo.dll"))
     (:linux   '("1" "0") '("libfoo.so.1" "libfoo.so.0" "libfoo.so")))
  (ok (equal (an:file-name-variants "foo" :versions versions :os os) expected)))

(deftest-parametrize partial-override
    ((os expected)
     (:darwin  '("libverdemo.2.dylib" "libverdemo.dylib"))
     (:linux   '("libverdemo.so.2" "libverdemo.so"))
     (:windows '("verdemo-2-x64.dll")))
  (ok (equal (an:native-library-names (lib "verdemo") :os os) expected)
      ":names for one OS leaves the others generated"))

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

(deftest-parametrize directory-templates
    ((template expected)
     ("lib/{pair}/" (format nil "lib/~A/" (an:host-pair)))
     ("{os}-{arch}" (an:host-pair))
     ("plain/" "plain/")
     ("" ""))
  (ok (equal (an:expand-directory-template template) expected)))

(deftest directory-template-env
  (with-env ("FLAVORDEMO" "cuda")
    (ok (equal (an:expand-directory-template "lib/{pair}-{env:FLAVORDEMO}/")
               (format nil "lib/~A-cuda/" (an:host-pair)))))
  (with-env ("FLAVORDEMO" "")
    (ok (null (an:expand-directory-template "lib/{pair}-{env:FLAVORDEMO}/"))
        "unset variable → directory skipped"))
  (ok (signals (an:expand-directory-template "{nope}") 'error) "unknown key")
  (ok (signals (an:expand-directory-template "{pair") 'error) "unclosed brace"))

(deftest extra-directories
  (let* ((root (asdf:system-source-directory (fixture-system)))
         (pair (an:host-pair))
         (tail (list (namestring (merge-pathnames "native/" root))
                     (namestring (merge-pathnames (format nil "lib/~A/" pair) root)))))
    (with-env ("FLAVORED_NATIVE" "")
      (with-env ("FLAVORDEMO" "cuda")
        (ok (equal (mapcar #'namestring (an:search-directories (lib "flavored")))
                   (list* (namestring (merge-pathnames (format nil "lib/~A-cuda/" pair) root))
                          (namestring root)
                          (format nil "/opt/flavored/~A/" (substitute #\/ #\- pair))
                          tail))
              "flavor dir, root, absolute dir, then the defaults"))
      (with-env ("FLAVORDEMO" "")
        (ok (equal (mapcar #'namestring (an:search-directories (lib "flavored")))
                   (list* (namestring root)
                          (format nil "/opt/flavored/~A/" (substitute #\/ #\- pair))
                          tail))
            "no flavor → its directory is skipped")))))

(deftest optional-missing
  (let ((c (lib "optional-lib")))
    (ok (signals (an:load-native-library c) 'an:native-library-missing) "warns")
    (ok (null (handler-bind ((warning #'muffle-warning)) (an:load-native-library c)))
        "returns NIL, does not signal an error")
    (ok (null (an:native-library-loaded-path c)))
    (ok (null (an:library-loaded-path "asdf-native-fixture" "optional-lib")))
    (ok (null (an:library-loaded-path "asdf-native-fixture" "no-such-component")))))

(deftest optional-with-system-fallback
  (let ((c (lib "optional-system-lib")))
    (let ((w (handler-case (an:load-native-library c)
               (an:native-library-missing (e) e))))
      (ok (typep w 'an:native-library-missing) "system search failed too → warning, not error")
      (ok (some (lambda (p) (search "(system search)" p)) (an:native-library-not-found-tried w))
          "the system search is listed as tried"))))

(deftest not-found
  (let ((c (lib "absent-lib")))
    (ok (null (an:find-native-library c)))
    (ok (signals (an:load-native-library c) 'an:native-library-not-found))
    (let ((condition (handler-case (an:load-native-library c)
                       (an:native-library-not-found (e) e))))
      (ok (= (* 2 (length (an:native-library-names c)))
             (length (an:native-library-not-found-tried condition)))
          "every name in both directories tried")
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
          ;; The same object under verdemo's versioned name only.
          (uiop:copy-file out (merge-pathnames (first (an:native-library-names (lib "verdemo"))) dir))
          (unwind-protect
               (with-env ("ANDEMO_NATIVE" (uiop:native-namestring dir))
                 (let ((c (lib "andemo")))
                   (ok (equal (an:find-native-library c) (truename out)) "found through the env dir")
                   (an:load-native-library c)
                   (ok (equal (an:native-library-loaded-path c) (truename out)) "loaded by absolute path")
                   (ok (member (truename dir) cffi:*foreign-library-directories* :test #'equal)
                       "directory pushed for its dependencies")
                   (ok (= 43 (cffi:foreign-funcall "andemo_answer" :int 1 :int)) "symbol callable")
                   (ok (equal (an:library-loaded-path "asdf-native-fixture" "andemo") (truename out))
                       "library-loaded-path")
                   (ok (asdf:operation-done-p (asdf:make-operation 'asdf:load-op) c) "done once loaded")
                   ;; A fresh component (a reloaded .asd) must not reopen it.
                   (let ((fresh (make-instance 'an:native-library :name "andemo"
                                                                  :parent (fixture-system))))
                     (let ((before #+sbcl (length sb-alien::*shared-objects*) #-sbcl 0))
                       (an:load-native-library fresh)
                       (ok (= before #+sbcl (length sb-alien::*shared-objects*) #-sbcl 0)
                           "same path is not reopened")
                       (ok (= 43 (cffi:foreign-funcall "andemo_answer" :int 1 :int))
                           "still callable"))))
                 (with-env ("VERDEMO_NATIVE" (uiop:native-namestring dir))
                   (let ((v (lib "verdemo")))
                     (ok (equal (file-namestring (an:find-native-library v))
                                (first (an:native-library-names v)))
                         "versioned variant found"))))
            ;; Windows keeps a loaded DLL locked; leave the temp dir there.
            (handler-case (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)
              (file-error () nil)))))))
