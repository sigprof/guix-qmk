;;; GNU Guix manifest for the QMK Firmware development environment
;;; Copyright © 2021-2023 Sergey Vlasov <sigprof@gmail.com>
;;; Copyright © 2022 Mark Dawson <markgdawson@gmail.com>
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This manifest file can be used to set up a development environment for the
;; QMK Firmware (https://github.com/qmk/qmk_firmware):
;;
;;   $ guix shell -m path/to/manifest.scm
;;
;; Or, if this manifest.scm file is in the current directory, "guix shell" will
;; load it automatically when invoked without parameters:
;;
;;   $ guix shell
;;
;; The resulting environment provides the "qmk" command that can be used to
;; compile the QMK firmware, and also the required toolchains for Arm-based and
;; AVR-based MCUs; it also provides some common flashing tools that are used
;; with those MCUs.
;;
;; Note that the system-wide configuration such as udev rules is not handled
;; here, therefore commands such as "qmk flash" or "qmk console" that actually
;; need to access the hardware may fail if that setup is not done.

(use-modules
  (ice-9 match)
  (srfi srfi-1)
  (guix licenses)
  (guix packages)
  (guix download)
  (guix git-download)
  (guix build-system pyproject)
  (guix build-system python)
  (guix build-system trivial)
  (guix search-paths))

(use-package-modules
  avr
  base
  bash
  check
  commencement
  compression
  embedded
  flashing-tools
  gcc
  libusb
  python
  python-build
  python-check
  python-xyz
  version-control
  wget)

;; "python-qmk" is the QMK CLI package which provides the "qmk" command.

(define python-qmk
  (package
    (name "python-qmk")
    (version "1.1.2")
    (source
      (origin
        (method url-fetch)
        (uri (pypi-uri "qmk" version))
        (sha256 (base32 "1619q9v90740dbg8xpzqlhwcasz42xj737803aiip8qc3a7zhwgq"))))
    (build-system pyproject-build-system)
    (arguments
     `(#:tests? #f))
    (propagated-inputs
     `(("python-hid" ,python-hid)
       ("python-pyusb" ,python-pyusb)
       ("python-milc" ,python-milc)
       ("python-setuptools" ,python-setuptools)
       ("python-dotty-dict" ,python-dotty-dict)
       ("python-hjson" ,python-hjson)
       ("python-jsonschema" ,python-jsonschema)
       ("python-pillow" ,python-pillow)
       ("python-pygments" ,python-pygments)
       ("python-pyserial" ,python-pyserial)))
    (home-page "https://qmk.fm/")
    (synopsis "QMK CLI is a program to help users work with QMK Firmware")
    (description "QMK CLI provides various functions for working with QMK Firmware: getting the QMK Firmware sources, setting up the build environment, compiling and flashing the firmware, accessing the debug console provided by the firmware, and many more functions used for the QMK Firmware configuration and development.")
    (license expat)))

;; Workaround for https://issues.guix.info/issue/39794#8 (the bug report is
;; closed, but the issue is not actually fixed) - all cross compilers use the
;; same CROSS_*_PATH environment variables, therefore including more than one
;; cross compiler in the profile breaks all of them except the last one,
;; because the include and library paths from all cross compilers get combined
;; into the same variables.

(define (qmk-wrap-toolchain toolchain-name toolchain-package toolchain-env-prefix)

  ;; Make a new list of inputs by applying PROC to all packages listed in
  ;; INPUTS and keeping the same labels and outputs.
  (define (map-inputs proc inputs)
    (define (rewrite input)
      (match input
        ((label (? package? package) outputs ...)
         (cons* label (proc package) outputs))
        (_
         input)))
    (map rewrite inputs))

  ;; Return the list of search path specifications from SEARCH-PATHS which
  ;; variable names are not found in the VAR-NAMES alist.
  (define (delete-from-search-paths search-paths var-names)
    (define (keep search-path)
      (not (assoc (search-path-specification-variable search-path) var-names)))
    (filter keep search-paths))

  ;; Return package ORIGINAL with search path specifications matching VAR-NAMES
  ;; removed from native-search-paths.
  (define (package-without-native-search-paths original var-names)
    (package/inherit original
      (native-search-paths
        (delete-from-search-paths (package-native-search-paths original) var-names))))

  ;; Make a new list of inputs from INPUTS by removing native search path
  ;; specifications matching VAR-NAMES from all listed packages.
  (define (inputs-without-native-search-paths inputs var-names)
    (define (rewrite package)
      (package-without-native-search-paths package var-names))
    (map-inputs rewrite inputs))

  (let* ((wrapper-name (string-append "qmk-" toolchain-name))
         (modules '((guix build utils)))

         ;; List of search paths set by the toolchain that must be saved.
         (saved-search-paths
           (filter
             (lambda (search-path)
               (let* ((var (search-path-specification-variable search-path)))
                 (and (string-prefix? "CROSS_" var)
                      (string-suffix? "_PATH" var))))
             (package-transitive-native-search-paths toolchain-package)))

         ;; Association list that maps the original environment variable names
         ;; for search paths to the architecture specific environment variable
         ;; names (which must not collide between different toolchains).
         (search-path-var-names
           (map
             (lambda (search-path)
               (let* ((var (search-path-specification-variable search-path)))
                 (cons var (string-append toolchain-env-prefix "_" var))))
           saved-search-paths))

         ;; List of new search paths with architecture specific environment
         ;; variable names.
         (new-search-paths
           (map
             (lambda (search-path)
               (search-path-specification
                 (inherit search-path)
                 (variable
                   (assoc-ref search-path-var-names
                              (search-path-specification-variable search-path)))))
             saved-search-paths))

         ;; Shell code for setting the environment variable values that would
         ;; actually be used by the compiler from the architecture specific
         ;; environment variables.  The code is a sequence of lines like:
         ;;   VAR="${ARCH_VAR}" \
         ;; (the last line also contains a backslash and is intended to
         ;; combine with the "exec" statement at the next line in the shell
         ;; wrapper script).
         (search-path-copy-code
           (apply string-append
                  (map
                    (lambda (var-mapping)
                      (string-append (car var-mapping) "=\"${" (cdr var-mapping) "}\" \\\n"))
                    search-path-var-names)))

         ;; The toolchain package with all CROSS_*_PATH native search paths
         ;; removed from its propagated inputs (these variables will be set to
         ;; their original values in the wrapper scripts, but leaving them
         ;; listed in native-search-paths will cause them to be exported with
         ;; inappropriately combined values taken from multiple different
         ;; toolchains).
         (new-toolchain-package
           (package/inherit toolchain-package
             (propagated-inputs
               (inputs-without-native-search-paths
                 (package-propagated-inputs toolchain-package)
                 search-path-var-names)))))

    ;; Generate a wrapper package with most properties copied from the original
    ;; toolchain package.
    (package
      (name wrapper-name)
      (version (package-version toolchain-package))
      (source #f)
      (build-system trivial-build-system)
      (arguments
       `(#:modules ,modules
         #:builder
         (begin
           ;; Generate wrapper scripts for all executables from the "gcc"
           ;; package in the toolchain.
           (use-modules ,@modules)
           (let* ((wrapper-bin-dir (string-append %output "/bin"))
                  (bash (assoc-ref %build-inputs "bash"))
                  (gcc (assoc-ref %build-inputs "gcc"))
                  (bash-binary (string-append bash "/bin/bash"))
                  (gcc-bin-dir (string-append gcc "/bin")))
             (mkdir %output)
             (mkdir wrapper-bin-dir)
             (for-each
               (lambda (bin)
                 (let* ((bin-name (basename bin))
                        (wrapper (string-append wrapper-bin-dir "/" bin-name)))
                   (call-with-output-file wrapper
                     (lambda (port)
                       (format port "#!~a~%~aexec ~a \"$@\"~%"
                               bash-binary
                               ,search-path-copy-code
                               bin)))
                   (chmod wrapper #o755)))
               (find-files gcc-bin-dir))
             #t))))
      (inputs
        `(("bash" ,bash)
          ("gcc" ,(first (assoc-ref (package-transitive-target-inputs toolchain-package) "gcc")))))
      (propagated-inputs
       `((,toolchain-name ,new-toolchain-package)))
      (native-search-paths new-search-paths)
      (synopsis (package-synopsis toolchain-package))
      (description (package-description toolchain-package))
      (home-page (package-home-page toolchain-package))
      (license (package-license toolchain-package)))))

(define qmk-avr-toolchain
  (qmk-wrap-toolchain "avr-toolchain"
                      (make-avr-toolchain #:xgcc gcc-8)
                      "AVR"))

;; Fix the bug from Guix commit 35c1df5bd6317b1cd038c1a4aca1c7e4a52d4d93 (the
;; package returned by (make-newlib-nano-arm-none-eabi-7-2018-q2-update) does
;; not contain libc_nano.a and libg_nano.a as expected).
(define newlib-nano-arm-none-eabi-7-2018-q2-update
  (package
    (inherit (make-newlib-nano-arm-none-eabi-7-2018-q2-update))
    (arguments
      (package-arguments (make-newlib-nano-arm-none-eabi)))))

;; Need to remake the toolchain package to include the fix above.
(define arm-none-eabi-nano-toolchain-7-2018-q2-update
  ((@@ (gnu packages embedded) make-arm-none-eabi-toolchain)
    (make-gcc-arm-none-eabi-7-2018-q2-update)
    newlib-nano-arm-none-eabi-7-2018-q2-update))

(define qmk-arm-none-eabi-nano-toolchain-7-2018-q2-update
  (qmk-wrap-toolchain "arm-none-eabi-nano-toolchain-7-2018-q2-update"
                      arm-none-eabi-nano-toolchain-7-2018-q2-update
                      "ARM_NONE_EABI_NANO"))

;; Finally make the manifest with all required packages.

(packages->manifest
  (list

    ;; Toolchains
    qmk-arm-none-eabi-nano-toolchain-7-2018-q2-update
    qmk-avr-toolchain

    ;; Flashing tools
    avrdude
    dfu-programmer
    dfu-util
    teensy-loader-cli

    ;; Other tools required for build
    git
    gnu-make
    python

    ;; QMK CLI
    python-qmk))
