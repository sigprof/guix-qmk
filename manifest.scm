;;; GNU Guix manifest for the QMK Firmware development environment
;;; Copyright © 2021-2023 Sergey Vlasov <sigprof@gmail.com>
;;; Copyright © 2022 Mark Dawson <markgdawson@gmail.com>
;;; Copyright © 2023 André A. Gomes <andremegafone@gmail.com>
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

(use-package-modules
  avr-xyz
  firmware
  flashing-tools
  python
  version-control)

(packages->manifest
 (list
  ;; Flashing tools
  avrdude
  dfu-programmer
  dfu-util
  simavr
  teensy-loader-cli
  ;; Other tools required for build
  git
  gnu-make
  ;; QMK CLI
  qmk))
