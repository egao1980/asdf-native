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
          :documentation "File names to try, in order. Default: DEFAULT-FILE-NAMES.
A plist (:darwin (...) :linux (...) :windows (...) :unix (...)) picks per OS;
a plain list applies everywhere.")
   (env :initarg :env :initform nil
        :documentation "Override variable naming a directory. Default <NAME>_NATIVE.")
   (system-fallback :initarg :system :initform nil :reader native-library-system-fallback-p
                    :documentation "T: when no directory has it, load the first name
through the dynamic linker's own search (a system library).")
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
               (format s "Native library ~A of system ~A not found. Tried:~{~%  ~A~}~%~
                          Set ~A to a directory holding it, or install the ~
                          system's platform overlay."
                       (asdf:component-name lib)
                       (asdf:component-name (asdf:component-system lib))
                       (native-library-not-found-tried c)
                       (native-library-env lib))))))

(defun host-pair ()
  "<os>-<arch> as used by lib/ directories and cl-repo overlays."
  (format nil "~A-~A"
          #+windows "windows" #+darwin "darwin" #+linux "linux"
          #+(and unix (not (or darwin linux))) "unix"
          #-(or windows darwin linux unix) "unknown"
          #+(or x86-64 x64 amd64) "amd64" #+(or arm64 aarch64) "arm64"
          #-(or x86-64 x64 amd64 arm64 aarch64) "unknown"))

(defun default-file-names (name)
  "foo → libfoo.dylib (macOS), foo.dll (Windows), libfoo.so (else)."
  (list #+darwin (format nil "lib~A.dylib" name)
        #+windows (format nil "~A.dll" name)
        #-(or darwin windows) (format nil "lib~A.so" name)))

(defun %os-key ()
  #+darwin :darwin #+windows :windows #+linux :linux
  #-(or darwin windows linux) :unix)

(defun native-library-names (lib)
  (let ((names (slot-value lib 'names)))
    (cond ((null names) (default-file-names (asdf:component-name lib)))
          ((keywordp (first names))
           (let ((os (%os-key)))
             (or (getf names os)
                 (and (member os '(:darwin :linux)) (getf names :unix))
                 (default-file-names (asdf:component-name lib)))))
          (t names))))

(defun native-library-env (lib)
  (or (slot-value lib 'env)
      (format nil "~:@(~A~)_NATIVE" (substitute #\_ #\- (asdf:component-name lib)))))

(defun search-directories (lib)
  "Env override, then <system>/native/, then <system>/lib/<os>-<arch>/."
  (let ((env (uiop:getenv (native-library-env lib)))
        (root (asdf:system-source-directory (asdf:component-system lib))))
    (append (when (and env (plusp (length env)))
              (list (uiop:ensure-directory-pathname env)))
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

(defun %load-path (path)
  (let ((dir (uiop:pathname-directory-pathname path)))
    (pushnew dir cffi:*foreign-library-directories* :test #'equal))
  (cffi:load-foreign-library (uiop:native-namestring path)))

(defun load-native-library (lib)
  "Load LIB once per image. Restarts on NATIVE-LIBRARY-NOT-FOUND: USE-VALUE
(a pathname to load instead), CONTINUE (skip; the system loads without it)."
  (or (native-library-loaded-path lib)
      (multiple-value-bind (path tried) (find-native-library lib)
        (cond (path
               (%load-path path)
               (setf (native-library-loaded-path lib) path))
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
