(in-package #:asdf-native)

;;; One ASDF component per native library:
;;;
;;;   (defsystem "foo"
;;;     :defsystem-depends-on ("asdf-native")
;;;     :components ((:file "package")
;;;                  (:native-library "foo-cl")   ; libfoo-cl.dylib / libfoo-cl.so / foo-cl.dll
;;;                  (:file "ffi")))
;;;
;;; At LOAD-OP it finds the library (FOO_CL_NATIVE, <system>/native/,
;;; <system>/lib/<os>-<arch>/), pushes that directory onto
;;; CFFI:*FOREIGN-LIBRARY-DIRECTORIES* (so a library it depends on, loaded by
;;; the dynamic linker, resolves there too) and loads it by absolute path.
;;; Several components load in component order: list dependencies first.
;;; No cl-repo involvement: cl-repo only puts files into native/.

(defclass native-library (asdf:component)
  ((names :initarg :names :initform nil
          :documentation "File names to try, in order, instead of the generated variants.
A plain list applies everywhere. A plist (:darwin (...) :linux (...) :windows (...)
:unix (...)) overrides only the OSes it names; the rest use FILE-NAME-VARIANTS.")
   (versions :initarg :versions :initform nil
             :documentation "ABI versions to try before the unversioned name, e.g. (\"3\"):
libfoo.3.dylib, libfoo.so.3, foo-3.dll / libfoo-3.dll.")
   (env :initarg :env :initform nil
        :documentation "Override variable naming a directory. Default <NAME>_NATIVE.")
   (system-fallback :initarg :system :initform nil :reader native-library-system-fallback-p
                    :documentation "T: when no directory has it, load the first name
through the dynamic linker's own search (a system library).")
   (optional :initarg :optional :initform nil :reader native-library-optional-p
             :documentation "T: a missing library warns (NATIVE-LIBRARY-MISSING) and the
system loads without it; LOADED-PATH stays NIL. For GPU runtimes and the like.")
   (directories :initarg :directories :initform nil
                :documentation "Extra directories searched after the env override and
before native/. Strings, relative to the system root unless absolute; \"\" is the
root itself. Templates: {pair} {os} {arch} {env:VAR}. A directory whose {env:VAR}
is unset or empty is skipped.")
   (loaded-path :initform nil :accessor native-library-loaded-path))
  (:documentation "A shared library the system loads at ASDF load, by absolute path."))

;;; ASDF resolves (:native-library ...) through ASDF/INTERFACE, as CFFI does
;;; for :cffi-grovel-file.
(setf (find-class (intern (symbol-name '#:native-library) '#:asdf/interface))
      (find-class 'native-library))

(define-condition native-library-not-found (error)
  ((component :initarg :component :reader native-library-not-found-component)
   (tried :initarg :tried :reader native-library-not-found-tried))
  (:report (lambda (c s)
             (let ((lib (native-library-not-found-component c)))
               ;; No ~<newline> directives: a CRLF checkout breaks them.
               (format s (concatenate 'string
                                      "Native library ~A of system ~A not found. Tried:~{~%  ~A~}~%"
                                      "Set ~A to a directory holding it, or install the "
                                      "system's platform overlay.")
                       (asdf:component-name lib)
                       (asdf:component-name (asdf:component-system lib))
                       (native-library-not-found-tried c)
                       (native-library-env lib))))))

(define-condition native-library-missing (warning)
  ((component :initarg :component :reader native-library-not-found-component)
   (tried :initarg :tried :reader native-library-not-found-tried))
  (:report (lambda (c s)
             (let ((lib (native-library-not-found-component c)))
               (format s "Optional native library ~A of system ~A not found; loading without it."
                       (asdf:component-name lib)
                       (asdf:component-name (asdf:component-system lib)))))))

(defun host-pair ()
  "<os>-<arch> as used by lib/ directories and cl-repo overlays."
  (format nil "~A-~A"
          #+windows "windows" #+darwin "darwin" #+linux "linux"
          #+(and unix (not (or darwin linux))) "unix"
          #-(or windows darwin linux unix) "unknown"
          #+(or x86-64 x64 amd64) "amd64" #+(or arm64 aarch64) "arm64"
          #-(or x86-64 x64 amd64 arm64 aarch64) "unknown"))

(defun %os-key ()
  #+darwin :darwin #+windows :windows #+linux :linux
  #-(or darwin windows linux) :unix)

(defun file-name-variants (name &key versions (os (%os-key)))
  "File names for library NAME on OS, most specific first: each of VERSIONS,
then unversioned.
  :darwin   libfoo.3.dylib … libfoo.dylib
  :windows  foo-3.dll libfoo-3.dll … foo.dll libfoo.dll  (MSVC and MinGW naming)
  else      libfoo.so.3 … libfoo.so"
  (append
   (loop for v in versions
         append (ecase os
                  (:darwin (list (format nil "lib~A.~A.dylib" name v)))
                  (:windows (list (format nil "~A-~A.dll" name v) (format nil "lib~A-~A.dll" name v)))
                  ((:linux :unix) (list (format nil "lib~A.so.~A" name v)))))
   (ecase os
     (:darwin (list (format nil "lib~A.dylib" name)))
     (:windows (list (format nil "~A.dll" name) (format nil "lib~A.dll" name)))
     ((:linux :unix) (list (format nil "lib~A.so" name))))))

(defun default-file-names (name)
  "FILE-NAME-VARIANTS of NAME on this host, without versions."
  (file-name-variants name))

(defun native-library-names (lib &key (os (%os-key)))
  "File names LIB tries on OS, in order."
  (let ((names (slot-value lib 'names))
        (generated (lambda ()
                     (file-name-variants (asdf:component-name lib)
                                         :versions (slot-value lib 'versions) :os os))))
    (cond ((null names) (funcall generated))
          ((keywordp (first names))
           (or (getf names os)
               (and (member os '(:darwin :linux)) (getf names :unix))
               (funcall generated)))
          (t names))))

(defun native-library-env (lib)
  (or (slot-value lib 'env)
      (format nil "~:@(~A~)_NATIVE" (substitute #\_ #\- (asdf:component-name lib)))))

(defun expand-directory-template (template)
  "TEMPLATE with {pair} {os} {arch} {env:VAR} filled in, or NIL when a
referenced variable is unset or empty."
  (let* ((pair (host-pair))
         (dash (position #\- pair))
         (out (make-string-output-stream))
         (i 0))
    (loop
      (let ((open (search "{" template :start2 i)))
        (unless open
          (write-string template out :start i)
          (return (get-output-stream-string out)))
        (let ((close (or (search "}" template :start2 open)
                         (error "Unclosed { in directory template ~S" template))))
          (write-string template out :start i :end open)
          (let ((key (subseq template (1+ open) close)))
            (write-string
             (cond ((string= key "pair") pair)
                   ((string= key "os") (subseq pair 0 dash))
                   ((string= key "arch") (subseq pair (1+ dash)))
                   ((and (> (length key) 4) (string= key "env:" :end1 4))
                    (let ((v (uiop:getenv (subseq key 4))))
                      (if (and v (plusp (length v))) v (return nil))))
                   (t (error "Unknown key {~A} in directory template ~S" key template)))
             out))
          (setf i (1+ close)))))))

(defun search-directories (lib)
  "Env override, then :DIRECTORIES, then <system>/native/, then <system>/lib/<os>-<arch>/."
  (let ((env (uiop:getenv (native-library-env lib)))
        (root (asdf:system-source-directory (asdf:component-system lib))))
    (append (when (and env (plusp (length env)))
              (list (uiop:ensure-directory-pathname env)))
            (loop for template in (slot-value lib 'directories)
                  for dir = (expand-directory-template template)
                  when dir
                    collect (let ((d (uiop:ensure-directory-pathname dir)))
                              (cond ((uiop:absolute-pathname-p d) d)
                                    (root (merge-pathnames d root))
                                    (t d))))
            (when root
              (list (merge-pathnames "native/" root)
                    (merge-pathnames (format nil "lib/~A/" (host-pair)) root))))))

(defun find-native-library (lib)
  "→ truename of the first NAME in the first directory that has one, and the
list of paths tried."
  (let ((tried '()))
    (dolist (dir (search-directories lib))
      (dolist (name (native-library-names lib))
        (let ((path (merge-pathnames name dir)))
          (push (namestring path) tried)
          (let ((found (probe-file path)))
            (when found (return-from find-native-library (values found (nreverse tried))))))))
    (values nil (nreverse tried))))

(defun %shared-object-loaded-p (path)
  "SBCL dlcloses and reopens a pathname it already has (a reloaded .asd makes
new components); skip those."
  #+sbcl (find (uiop:native-namestring path) sb-alien::*shared-objects*
               :key (lambda (o) (ignore-errors (uiop:native-namestring
                                                 (sb-alien::shared-object-pathname o))))
               :test #'equal)
  #-sbcl (declare (ignore path))
  #-sbcl nil)

(defun %load-path (path)
  (let ((dir (uiop:pathname-directory-pathname path)))
    (pushnew dir cffi:*foreign-library-directories* :test #'equal))
  (unless (%shared-object-loaded-p path)
    (cffi:load-foreign-library (uiop:native-namestring path))))

(defun load-native-library (lib)
  "Load LIB once per image. Restarts on NATIVE-LIBRARY-NOT-FOUND: USE-VALUE
(a pathname to load instead), CONTINUE (skip; the system loads without it)."
  (or (native-library-loaded-path lib)
      (multiple-value-bind (path tried) (find-native-library lib)
        (cond (path
               (%load-path path)
               (setf (native-library-loaded-path lib) path))
              ((native-library-optional-p lib)
               (warn 'native-library-missing :component lib :tried tried)
               nil)
              ((native-library-system-fallback-p lib)
               (let ((name (first (native-library-names lib))))
                 (cffi:load-foreign-library name)
                 (setf (native-library-loaded-path lib) name)))
              (t
               (restart-case (error 'native-library-not-found :component lib :tried tried)
                 (use-value (path)
                   :report "Load a library from a pathname you supply."
                   :interactive (lambda () (format *query-io* "Path: ") (list (read-line *query-io*)))
                   (%load-path (truename path))
                   (setf (native-library-loaded-path lib) (truename path)))
                 (continue ()
                   :report "Skip this library."
                   nil)))))))

;;; ASDF plumbing: nothing to compile, no input or output files.

(defmethod asdf:component-relative-pathname ((c native-library)) nil)
(defmethod asdf:input-files ((o asdf:operation) (c native-library)) nil)
(defmethod asdf:output-files ((o asdf:operation) (c native-library)) (values nil t))
(defmethod asdf:perform ((o asdf:compile-op) (c native-library)) nil)
(defmethod asdf:perform ((o asdf:load-op) (c native-library)) (load-native-library c))
(defmethod asdf:perform ((o asdf:load-source-op) (c native-library)) (load-native-library c))

;;; A fresh image (or a restored core) has none loaded yet: redo LOAD-OP.
(defmethod asdf:operation-done-p ((o asdf:load-op) (c native-library))
  (and (native-library-loaded-path c) t))

(defun library-loaded-path (system name)
  "Path the :NATIVE-LIBRARY component NAME of SYSTEM loaded, or NIL (not
loaded, or optional and missing). For a system's own *-AVAILABLE-P."
  (let* ((sys (asdf:find-system system nil))
         (c (and sys (asdf:find-component sys name))))
    (and (typep c 'native-library) (native-library-loaded-path c))))
