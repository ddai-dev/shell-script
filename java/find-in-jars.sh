#!/bin/bash
# @Function
# Find file in the jar files under current directory
#
# @Usage
#   $ find-in-jars 'log4j\.properties'
#   $ find-in-jars '^log4j\.(properties|xml)$' # search file log4j.properties/log4j.xml at zip root
#   $ find-in-jars 'log4j\.properties$' -d /path/to/find/directory
#   $ find-in-jars '\.properties$' -d /path/to/find/dir1 -d path/to/find/dir2
#   $ find-in-jars 'Service\.class$' -e jar -e zip
#   $ find-in-jars 'Mon[^$/]*Service\.class$' -s ' <-> '
#
# @online-doc https://github.com/oldratlee/useful-scripts/blob/master/docs/java.md#-find-in-jars
# @author Jerry Lee (oldratlee at gmail dot com)

readonly PROG="`basename "$0"`"

################################################################################
# util functions
################################################################################

[ -t 1 ] && readonly is_console=true || readonly is_console=false

# NOTE: $'foo' is the escape sequence syntax of bash
readonly ec=$'\033'      # escape char
readonly eend=$'\033[0m' # escape end
readonly cr=$'\r'        # carriage return

redEcho() {
    $is_console && echo "$ec[1;31m$@$eend" || echo "$@"
}

die() {
    redEcho "Error: $@" 1>&2
    exit 1
}

# Getting console width using a bash script
# https://unix.stackexchange.com/questions/299067
$is_console && readonly columns=$(stty size | awk '{print $2}')

printResponsiveMessage() {
    $is_console || return

    local message="$*"
    # http://www.linuxforums.org/forum/red-hat-fedora-linux/142825-how-truncate-string-bash-script.html
    echo -n "${message:0:columns}"
}

clearResponsiveMessage() {
    $is_console || return

    # How to delete line with echo?
    # https://unix.stackexchange.com/questions/26576
    #
    # terminal escapes: http://ascii-table.com/ansi-escape-sequences.php
    # In particular, to clear from the cursor position to the beginning of the line:
    # echo -e "\033[1K"
    # Or everything on the line, regardless of cursor position:
    # echo -e "\033[2K"
    echo -n "$ec[2K$cr"
}

usage() {
    local -r exit_code="$1"
    shift
    [ -n "$exit_code" -a "$exit_code" != 0 ] && local -r out=/dev/stderr || local -r out=/dev/stdout

    (( $# > 0 )) && { echo "$@"; echo; } > $out

    > $out cat <<EOF
Usage: ${PROG} [OPTION]... PATTERN
Find file in the jar files under specified directory(recursive, include subdirectory).
The pattern default is *extended* regex.
Example:
  ${PROG} 'log4j\.properties'
  ${PROG} '^log4j\.(properties|xml)$' # search file log4j.properties/log4j.xml at zip root
  ${PROG} 'log4j\.properties$' -d /path/to/find/directory
  ${PROG} '\.properties$' -d /path/to/find/dir1 -d path/to/find/dir2
  ${PROG} 'Service\.class$' -e jar -e zip
  ${PROG} 'Mon[^$/]*Service\.class$' -s ' <-> '
Find control:
  -d, --dir              the directory that find jar files, default is current directory.
                         this option can specify multiply times to find in multiply directories.
  -e, --extension        set find file extension, default is jar.
                         this option can specify multiply times to find in multiply extension.
  -E, --extended-regexp  PATTERN is an extended regular expression (*default*)
  -F, --fixed-strings    PATTERN is a set of newline-separated strings
  -G, --basic-regexp     PATTERN is a basic regular expression
  -P, --perl-regexp      PATTERN is a Perl regular expression
  -i, --ignore-case      ignore case distinctions
Output control:
  -a, --absolute-path    always print absolute path of jar file
  -s, --seperator        seperator for jar file and file entry, default is \`!'.
Miscellaneous:
  -h, --help             display this help and exit
EOF

    exit $1
}

################################################################################
# parse options
################################################################################

declare -a args=()
declare -a dirs=()
while (( $# > 0 )); do
    case "$1" in
    -d|--dir)
        dirs=("${dirs[@]}" "$2")
        shift 2
        ;;
    -e|--extension)
        extension=("${extension[@]}" "$2")
        shift 2
        ;;
    -s|--seperator)
        seperator="$2"
        shift 2
        ;;
    -E|--extended-regexp)
        regex_mode=-E
        shift
        ;;
    -F|--fixed-strings)
        regex_mode=-F
        shift
        ;;
    -G|--basic-regexp)
        regex_mode=-G
        shift
        ;;
    -P|--perl-regexp)
        regex_mode=-P
        shift
        ;;
    -i|--ignore-case)
        ignore_case_option=-i
        shift
        ;;
    -a|--absolute-path)
        use_absolute_path=true
        shift
        ;;
    -h|--help)
        usage
        ;;
    --)
        shift
        args=("${args[@]}" "$@")
        break
        ;;
    -*)
        usage 2 "${PROG}: unrecognized option '$1'"
        ;;
    *)
        args=("${args[@]}" "$1")
        shift
        ;;
    esac
done

dirs=${dirs:-.}
extension=${extension:-jar}
regex_mode=${regex_mode:--E}

use_absolute_path=${use_absolute_path:-false}
seperator="${seperator:-!}"

(( "${#args[@]}" == 0 )) && usage 1 "No find file pattern!"
(( "${#args[@]}" > 1 )) && usage 1 "More than 1 file pattern: ${args[@]}"
readonly pattern="${args[0]}"

declare -a tmp_dirs=()
for d in "${dirs[@]}"; do
    [ -e "$d" ] || die "file $d(specified by option -d) does not exist!"
    [ -d "$d" ] || die "file $d(specified by option -d) exists but is not a directory!"
    [ -r "$d" ] || die "directory $d(specified by option -d) exists but is not readable!"
    # convert dirs to Absolute Path
    $use_absolute_path && tmp_dirs=( "${tmp_dirs[@]}" "$(cd "$d" && pwd)" )
done
# set dirs to Absolute Path
$use_absolute_path && dirs=( "${tmp_dirs[@]}" )

# convert extensions to find -iname options
for e in "${extension[@]}"; do
    (( "${#find_iname_options[@]}" == 0 )) &&
        find_iname_options=( -iname "*.$e" ) ||
        find_iname_options=( "${find_iname_options[@]}" -o -iname "*.$e" )
done

################################################################################
# Check the existence of command for listing zip entry!
################################################################################

# `zipinfo -1`/`unzip -Z1` is ~25 times faster than `jar tf`, find zipinfo/unzip command first.
#
# How to list files in a zip without extra information in command line
# https://unix.stackexchange.com/a/128304/136953
if which zipinfo &> /dev/null; then
    readonly command_for_list_zip='zipinfo -1'
elif which unzip &> /dev/null; then
    readonly command_for_list_zip='unzip -Z1'
else
    if ! which jar &> /dev/null; then
        [ -n "$JAVA_HOME" ] || die "jar not found on PATH and JAVA_HOME env var is blank!"
        [ -f "$JAVA_HOME/bin/jar" ] || die "jar not found on PATH and \$JAVA_HOME/bin/jar($JAVA_HOME/bin/jar) file does NOT exists!"
        [ -x "$JAVA_HOME/bin/jar" ] || die "jar not found on PATH and \$JAVA_HOME/bin/jar($JAVA_HOME/bin/jar) is NOT executalbe!"
        export PATH="$JAVA_HOME/bin:$PATH"
    fi
    readonly command_for_list_zip='jar tf'
fi

################################################################################
# find logic
################################################################################

readonly jar_files="$(find "${dirs[@]}" "${find_iname_options[@]}" -type f)"
readonly total_count="$(echo $(echo "$jar_files" | wc -l))"
[ -n "$jar_files" ] || die "No ${extension[@]} file found!"

findInJarFiles() {
    $is_console && local -r grep_color_option='--color=always'

    local counter=1
    local jar_file
    while read jar_file; do
        printResponsiveMessage "finding in jar($((counter++))/$total_count): $jar_file"

        $command_for_list_zip "${jar_file}" |
            grep $regex_mode $ignore_case_option $grep_color_option -- "$pattern" |
            while read file; do
                clearResponsiveMessage

                $is_console &&
                    echo "$ec[1;35m${jar_file}${eend}${ec}[1;32m${seperator}${eend}${file}" ||
                    echo "${jar_file}${seperator}${file}"
            done

        clearResponsiveMessage
    done
}

echo "$jar_files" | findInJarFiles
