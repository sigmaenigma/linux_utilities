#!/usr/bin/env bash
# v1.3
# System update for Raspberry Pi OS / Debian.
# Usage: ./rpi-update.sh        interactive, asks before upgrading
#        ./rpi-update.sh -y     unattended, answers yes automatically

# ---------------------------------------------------------------------------
# Shell safety settings
# ---------------------------------------------------------------------------
# -e            exit immediately if any command returns a non-zero (failure)
#               status. Without this, the script plows on after errors and
#               still prints "completed" at the end, which is what the
#               original did.
# -u            treat use of an undefined variable as an error. Catches typos
#               like $remainng instead of $remaining.
# -o pipefail   in a pipeline (a | b | c), fail if ANY stage fails. By default
#               bash only looks at the last command's exit status.
set -euo pipefail

# ---------------------------------------------------------------------------
# Get root once, up front
# ---------------------------------------------------------------------------
# $EUID is the effective user ID of whoever is running this. 0 means root.
# -ne is "not equal" (numeric comparison).
if [ "${EUID}" -ne 0 ]; then
    # exec REPLACES the current process rather than spawning a child, so we
    # do not end up with two copies of the script running.
    # "$0" is the path to this script. "$@" passes along every argument you
    # typed, so the -y flag survives the jump to root.
    # Net effect: one password prompt at the start, instead of one per apt
    # command and a chance of being asked again halfway through.
    exec sudo "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
ASSUME_YES=""
# ${1:-} means "the first argument, or an empty string if there isn't one".
# The :- part matters because set -u would abort on a bare $1 when you run
# the script with no arguments.
if [ "${1:-}" = "-y" ]; then
    ASSUME_YES="-y"
fi

# Tells package install scripts not to pop up interactive dialogs (those
# purple full-screen config prompts). Required if this ever runs from cron,
# where there is no terminal to answer them.
export DEBIAN_FRONTEND=noninteractive

# -o passes a configuration option to apt. Dpkg::Options:: are handed further
# down to dpkg itself. The two here decide what happens when a package ships
# a new version of a config file you may have edited:
#   --force-confold   you edited it     -> KEEP YOUR VERSION
#   --force-confdef   you never touched it -> take the package's new default
# Together they mean an unattended run can never silently overwrite your edits.
# This is an array (the parentheses) so the options stay as separate arguments.
APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

# A function. $1 inside it is the argument passed to the function, not to the
# script. >&2 sends the message to stderr instead of stdout, so it still shows
# up if you redirect normal output to a log file. exit 1 signals failure to
# whatever called this script (cron, another script, your shell's $?).
fail() { echo "FAILED at: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Update package lists
# ---------------------------------------------------------------------------
echo "Starting system update..."

# Downloads the index files describing what versions the repos currently hold.
# This installs nothing. It only refreshes apt's idea of what is available.
#   -qq   "quiet, twice over". -q drops the progress bars, -qq also drops the
#         per-repository Hit:/Get: lines, leaving only real warnings and
#         errors. Useful here because that chatter is noise you never act on.
# || fail "..."  runs the fail function if apt-get returns non-zero.
apt-get update -qq || fail "apt-get update"

# ---------------------------------------------------------------------------
# Show what is about to change
# ---------------------------------------------------------------------------
echo
echo "Pending upgrades:"
# Note this uses apt, not apt-get. apt has the friendlier list output; apt-get
# has the stable interface meant for scripts. So: apt for showing humans
# things, apt-get for anything whose exit code or output we depend on.
#   2>/dev/null          discards stderr, which is where apt prints its
#                        "apt does not have a stable CLI interface" warning
#   grep -v '^Listing'   -v inverts the match, so this DROPS lines starting
#                        with "Listing", i.e. the header
#   || true              grep exits 1 when it finds no matches. Under set -e
#                        that would kill the script on a system with nothing
#                        to upgrade. || true forces a success exit code.
apt list --upgradable 2>/dev/null | grep -v '^Listing' || true

# ---------------------------------------------------------------------------
# The upgrade itself
# ---------------------------------------------------------------------------
echo
# "${APT_OPTS[@]}" expands the array into separate arguments, quoted properly.
# ${ASSUME_YES} is deliberately NOT quoted: when it is empty we want it to
# vanish entirely, and quoting would pass an empty string as an argument.
apt-get "${APT_OPTS[@]}" ${ASSUME_YES} upgrade || fail "apt-get upgrade"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo
echo "Removing orphaned packages..."
# Removes packages that were installed automatically as dependencies of
# something else, and which nothing needs any more.
apt-get ${ASSUME_YES} autoremove || fail "apt-get autoremove"

echo "Cleaning package cache..."
# Deletes downloaded .deb files from /var/cache/apt/archives, but only those
# for versions that are no longer available in the repos. The blunter "clean"
# deletes every cached .deb; autoclean is the conservative cousin.
apt-get autoclean -qq || fail "apt-get autoclean"

# ---------------------------------------------------------------------------
# Held-back check
# ---------------------------------------------------------------------------
# The original script had no equivalent of this. Anything still showing as
# upgradable AFTER the upgrade ran is something apt declined to touch, and
# without this you would only ever see it buried in a summary line.
echo
remaining="$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)"
# -n tests for "string is not empty"
if [ -n "${remaining}" ]; then
    echo "*** HELD BACK, NOT UPGRADED ***"
    echo "${remaining}"
    echo
    # -s means simulate: apt-get prints what it WOULD do and changes nothing.
    echo "To see why, run:  apt-get -s install <package>"
fi

# ---------------------------------------------------------------------------
# Reboot check
# ---------------------------------------------------------------------------
reboot_needed=0

# /run/reboot-required is created by the update-notifier-common package when
# something needing a reboot gets installed. That package is not part of a
# default Raspberry Pi OS install, so on this box the file may never appear.
# Confirm with:  dpkg -l update-notifier-common
# -f tests "this path exists and is a regular file".
if [ -f /run/reboot-required ]; then
    reboot_needed=1
    echo
    echo "*** REBOOT REQUIRED ***"
    cat /run/reboot-required.pkgs 2>/dev/null || echo "Package list not available"
fi

# Independent check that does not depend on any extra package being installed:
# compare the kernel currently RUNNING against the newest one INSTALLED.
running="$(uname -r)"                   # e.g. 6.18.39+rpt-rpi-v6
arch="$(dpkg --print-architecture)"     # e.g. armhf

# This box has both -rpi-v6 and -rpi-v7 kernels installed, at the same version.
# Comparing across flavours makes sort -V rank v7 above v6, which produced a
# permanent false "KERNEL CHANGED" warning. So: isolate the flavour of the
# running kernel and only compare against the same flavour.
# ${running#*+} deletes the shortest match of "*+" from the FRONT of the
# string, turning "6.18.39+rpt-rpi-v6" into "rpt-rpi-v6".
flavour=""
case "${running}" in
    *+*) flavour="+${running#*+}" ;;    # only if there is a + to split on
esac

# Pipeline, stage by stage:
#   dpkg-query -W 'linux-image-*'   list installed packages matching the glob.
#                                   -W is "show", -f is a custom output format
#                                   using dpkg's ${Field} placeholders.
#   awk '$1==a {print $2}'          keep only rows whose first field (the
#                                   architecture) equals our native arch, and
#                                   print the second field (the name).
#                                   -v a="..." passes a shell value into awk.
#   sed 's/^linux-image-//'         strip the prefix so names line up with
#                                   what uname -r reports
#   grep -E '^[0-9]'                keep only entries starting with a digit,
#                                   which drops metapackages like "rpi-v6"
#   grep -F -- "${flavour}"         -F matches a literal string rather than a
#                                   regex. The -- stops grep from reading a
#                                   leading "+" as a command-line flag.
#   sort -V                         version sort, so 6.18.39 beats 6.18.9
#                                   (a plain sort would get that backwards)
#   tail -1                         keep the highest
newest="$(dpkg-query -W -f='${Architecture} ${Package}\n' 'linux-image-*' 2>/dev/null \
    | awk -v a="${arch}" '$1==a {print $2}' \
    | sed 's/^linux-image-//' \
    | grep -E '^[0-9]' \
    | grep -F -- "${flavour}" \
    | sort -V | tail -1 || true)"

# != is string inequality. The -n guard stops this firing if the pipeline
# above came back empty for some reason.
if [ -n "${newest}" ] && [ "${running}" != "${newest}" ]; then
    reboot_needed=1
    echo
    echo "*** KERNEL CHANGED ***"
    echo "  running:   ${running}"
    echo "  installed: ${newest}"
    echo "Reboot to pick up the new kernel."
fi

if [ "${reboot_needed}" -eq 0 ]; then
    echo "No reboot required."
fi

echo
echo "System update completed."
