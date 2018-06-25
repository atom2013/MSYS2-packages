#!/bin/bash

# Continuous Integration Library for MSYS2
# Author: Renato Silva <br.renatosilva@gmail.com>
# Author: Qian Hong <fracting@gmail.com>

# Enable colors
if [[ -t 1 ]]; then
    normal='\e[0m'
    red='\e[1;31m'
    green='\e[1;32m'
    cyan='\e[1;36m'
fi

# Basic status function
_status() {
    local type="${1}"
    local status="${package:+${package}: }${2}"
    local items=("${@:3}")
    case "${type}" in
        failure) local -n nameref_color='red';   title='[MSYS2 CI] FAILURE:' ;;
        success) local -n nameref_color='green'; title='[MSYS2 CI] SUCCESS:' ;;
        message) local -n nameref_color='cyan';  title='[MSYS2 CI]'
    esac
    printf "\n${nameref_color}${title}${normal} ${status}\n\n"
    printf "${items:+\t%s\n}" "${items:+${items[@]}}"
}

# Convert lines to array
_as_list() {
    local -n nameref_list="${1}"
    local filter="${2}"
    local strip="${3}"
    local lines="${4}"
    local result=1
    nameref_list=()
    while IFS= read -r line; do
        test -z "${line}" && continue
        result=0
        [[ "${line}" = ${filter} ]] && nameref_list+=("${line/${strip}/}")
    done <<< "${lines}"
    return "${result}"
}

# Changes since master or from head
_list_changes() {
    local list_name="${1}"
    local filter="${2}"
    local strip="${3}"
    local git_options=("${@:4}")
    _as_list "${list_name}" "${filter}" "${strip}" "$(git log "${git_options[@]}" upstream/master.. | sort -u)" ||
    _as_list "${list_name}" "${filter}" "${strip}" "$(git log "${git_options[@]}" HEAD^.. | sort -u)"
}

# Changes from head
_list_changes_from_head() {
    local list_name="${1}"
    local filter="${2}"
    local strip="${3}"
    local git_options=("${@:4}")
    _as_list "${list_name}" "${filter}" "${strip}" "$(git log "${git_options[@]}" HEAD^.. | sort -u)"
}

# Changes since last build
_list_changes_from_marker() {
    local list_name="${1}"
    local filter="${2}"
    local strip="${3}"
    local git_options=("${@:4}")
	local marker="${PACMAN_REPOSITORY_NAME:-msys}-build.marker"
    local branch_url="$(git remote get-url origin | sed 's/\.git$//')/tree/${CI_BRANCH}"
	local commit_sha
	
	_download_previous binary "${marker}" && commit_sha=$(sed -rn "s|${branch_url}\s+([[:xdigit:]]+).*|\1|p" "${marker}")
	rm -f ${marker}
	[ -n "${commit_sha}" ] || commit_sha="HEAD^"
	
	_as_list "${list_name}" "${filter}" "${strip}" "$(git log "${git_options[@]}" ${commit_sha}.. | sort -u)"
}

# Get package information
_package_info() {
    local package="${1}"
    local properties=("${@:2}")
    for property in "${properties[@]}"; do
        local -n nameref_property="${property}"
        nameref_property=($(
            source "${package}/PKGBUILD"
            declare -n nameref_property="${property}"
            echo "${nameref_property[@]}"))
    done
}

# Package provides another
_package_provides() {
    local package="${1}"
    local another="${2}"
    local pkgname provides
    _package_info "${package}" pkgname provides
    for pkg_name in "${pkgname[@]}";  do [[ "${pkg_name}" = "${another}" ]] && return 0; done
    for provided in "${provides[@]}"; do [[ "${provided}" = "${another}" ]] && return 0; done
    return 1
}

# Add package to build after required dependencies
_build_add() {
    local package="${1}"
    local depends makedepends
    for sorted_package in "${sorted_packages[@]}"; do
        [[ "${sorted_package}" = "${package}" ]] && return 0
    done
    _package_info "${package}" depends makedepends
    for dependency in "${depends[@]}" "${makedepends[@]}"; do
        for unsorted_package in "${packages[@]}"; do
            [[ "${package}" = "${unsorted_package}" ]] && continue
            _package_provides "${unsorted_package}" "${dependency}" && _build_add "${unsorted_package}"
        done
    done
    sorted_packages+=("${package}")
}

# Download previous artifact
_download_previous() {
	local type=${1}
	shift
    local filenames=("${@}")
	local remote_dir
    [[ "${DEPLOY_PROVIDER}" = bintray ]] || return 1
	case ${type} in
		distrib) remote_dir=https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${ARCH};;
		binary) remote_dir=https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${ARCH};;
		sources) remote_dir=https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/sources;;
	esac
    for filename in "${filenames[@]}"; do
        if ! wget --no-verbose "${remote_dir}/${filename}"; then
            rm -f "${filenames[@]}"
            return 1
        fi
    done
    return 0
}

# Git configuration
git_config() {
    local name="${1}"
    local value="${2}"
    test -n "$(git config ${name})" && return 0
    git config --global "${name}" "${value}" && return 0
    failure 'Could not configure Git for makepkg'
}

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
	[ -n "${package}" ] && pushd ${package}
    message "${status}"
    if [[ "${command}" != *:* ]]
        then ${command} ${arguments[@]}
        else ${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
    [ -n "${package}" ] && popd
}

# Update system
update_system() {
    repman add ${PACMAN_REPOSITORY_NAME} "https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${ARCH}" || return 1
    pacman --noconfirm --noprogressbar --sync --refresh --refresh --sysupgrade --sysupgrade || return 1
    test -n "${DISABLE_QUALITY_CHECK}" && return 0 # TODO: remove this option when not anymore needed
    pacman --noconfirm --needed --noprogressbar --sync ${PACMAN_REPOSITORY_NAME}/pactoys
}

# Sort packages by dependency
define_build_order() {
    local sorted_packages=()
    for unsorted_package in "${packages[@]}"; do
        _build_add "${unsorted_package}"
    done
    packages=("${sorted_packages[@]}")
}

# Associate artifacts with this build
create_build_references() {
    local repository_name="${1}"
    local references="${repository_name}.builds"
	(ls artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/*.pkg.tar.xz &>/dev/null) && {
	pushd artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}
    _download_previous binary "${references}" || touch "${references}"
    for file in *.pkg.tar.xz; do
        sed -i "/^${file}.*/d" "${references}"
        printf '%-80s%s\n' "${file}" "${CI_BUILD_URL}" >> "${references}"
    done
    sort "${references}" | tee "${references}.sorted" | sed -r 's/(\S+)\s.*\/([^/]+)/\2\t\1/'
    mv "${references}.sorted" "${references}"
	popd
	} || {
	echo "Skiped, no file 'artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/*.pkg.tar.xz'"
	}
}

# Add packages to repository
create_pacman_repository() {
    local name="${1}"
	(ls artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/*.pkg.tar.xz &>/dev/null) && {
	local LANG_bkp=${LANG}
	export LANG=en_US.UTF-8
	
	pushd artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}
    _download_previous binary "${name}".{db,files}{,.tar.xz}
    repo-add "${name}.db.tar.xz" *.pkg.tar.xz | tee /dev/stderr | grep -Po "\bRemoving existing entry '\K[^']+(?=')" >> old_pkg.list
	popd

	export LANG=${LANG_bkp}
	} || {
	echo "Skiped, no file 'artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/*.pkg.tar.xz'"
	}
}

# log git sha for the current build
create_build_marker() {
	local name="${1}"
	local branch_url="$(git remote get-url origin | sed 's/\.git$//')/tree/${CI_BRANCH}"
	local marker="${name}-build.marker"

	[ -d artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH} ] || return 1
	
	pushd artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}
	_download_previous binary "${marker}" || touch "${marker}"
	(grep -q "${branch_url}" "${marker}") && \
	sed -i -r "s|(${branch_url}\\s*).*|\1${CI_COMMIT}|g" "${marker}" || \
	printf '%-80s%s\n' "${branch_url}" "${CI_COMMIT}" >> "${marker}"
	popd
}

# Deployment is enabled
deploy_enabled() {
    test -n "${CI_BUILD_URL}" || return 1
    [[ "${DEPLOY_PROVIDER}" = bintray ]] || return 1
	[ -n "${PACMAN_REPOSITORY_NAME}" ] || return 1
	local LOCAL_REPOSITORY_PATH="artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}"
	[ -f "${LOCAL_REPOSITORY_PATH}/${PACMAN_REPOSITORY_NAME}.db" ] || return 1
	[ -f "${LOCAL_REPOSITORY_PATH}/${PACMAN_REPOSITORY_NAME}.files" ] || return 1
	return 0
}

# Distribution is enabled
distrib_enable() {
	[ -n "${DISTRIB_PACKAGE_NAME}" ] && [ -n "${ARCH}" ] || return 1
	local LOCAL_REPOSITORY_PATH="artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}"
	[ -f ${LOCAL_REPOSITORY_PATH}/packages.list ] && {
	local pkg basepkgs
	pacman --sync --refresh
	basepkgs=($(for pkg in $(pacman -Qg base | cut -d ' ' -f2); do pactree -lu ${pkg}; done | sort -u))
	pkg=$(echo $(cat ${LOCAL_REPOSITORY_PATH}/packages.list | sort -u) | sed -r 's/\S+/\\b&\\b/g' | tr ' ' '|')
	[ -n "${pkg}" ] && (grep -Pq "${pkg}" <<< ${basepkgs[@]}) && return 0
	}
	return 1;
}

# Added commits
list_commits()  {
    _list_changes commits '*' '#*::' --pretty=format:'%ai::[%h] %s'
}

# Added commits from head
list_commits_from_head()  {
    _list_changes_from_head commits '*' '#*::' --pretty=format:'%ai::[%h] %s'
}

# Added commits since last build
list_commits_from_marker()  {
    _list_changes_from_marker commits '*' '#*::' --pretty=format:'%ai::[%h] %s'
}

# Changed recipes
list_packages() {
    local _packages
    _list_changes _packages '*/PKGBUILD' '%/PKGBUILD' --pretty=format: --name-only || return 1
    for _package in "${_packages[@]}"; do
        local find_case_sensitive="$(find -name "${_package}" -type d -print -quit)"
        test -n "${find_case_sensitive}" && packages+=("${_package}")
    done
    return 0
}

# Changed recipes
list_packages_from_head() {
    local _packages
    _list_changes_from_head _packages '*/PKGBUILD' '%/PKGBUILD' --pretty=format: --name-only || return 1
    for _package in "${_packages[@]}"; do
        local find_case_sensitive="$(find -name "${_package}" -type d -print -quit)"
        test -n "${find_case_sensitive}" && packages+=("${_package}")
    done
    return 0
}

# Changed recipes
list_packages_from_marker() {
    local _packages
    _list_changes_from_marker _packages '*/PKGBUILD' '%/PKGBUILD' --pretty=format: --name-only || return 1
    for _package in "${_packages[@]}"; do
        local find_case_sensitive="$(find -name "${_package}" -type d -print -quit)"
        test -n "${find_case_sensitive}" && packages+=("${_package}")
    done
    return 0
}

# Recipe quality
check_recipe_quality() {
    # TODO: remove this option when not anymore needed
    if test -n "${DISABLE_QUALITY_CHECK}"; then
        echo 'This feature is disabled.'
        return 0
    fi
    saneman --format='\t%l:%c %p:%c %m' --verbose --no-terminal "${packages[@]}"
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; exit 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; exit 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }

# Remove redundant system files
purge_system_files()
{
local root="$([ "${1}" ] && cygpath ${1})"
[ -d ${root}/home ] && rm -rf ${root}/home
[ -d ${root}/tmp ] && rm -rf ${root}/tmp/*
[ -d ${root}/var/cache/pacman/pkg ] && rm -rf ${root}/var/cache/pacman/pkg/*
[ -d ${root}/var/cache/pacman/pkgfile ] && rm -rf ${root}/var/cache/pacman/pkgfile/*
[ -d ${root}/var/log ] && rm -rf ${root}/var/log/*
[ -d ${root}/etc/pacman.d/gnupg ] && rm -rf ${root}/etc/pacman.d/gnupg
}

# Function: Sign one or more pkgballs.
create_package_signature()
{
[ -n "${GPG_KEY_PASSWD}" ] || { echo "You must set GPG_KEY_PASSWD firstly."; return 1; } 
local all_types=("${@}")
local type pkg
local LANG_bkp=${LANG}

export LANG=en_US.UTF-8

for type in ${all_types[@]}; do
case ${type} in
	distrib)
# signature for distrib packages.
[ -d artifacts/${DISTRIB_PACKAGE_NAME}/${ARCH} ] && {
pushd artifacts/${DISTRIB_PACKAGE_NAME}/${ARCH}
for pkg in *.tar.xz; do
expect << _EOF
spawn gpg -o "${pkg}.sig" -b "${pkg}"
expect {
"Enter passphrase:" {
					send "${GPG_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done
popd
}
;;
	binary)
# signature for binary packages.
[ "${type}" == "binary" ] && [ -d artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH} ] && {
pushd artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}
for pkg in *.pkg.tar.xz; do
expect << _EOF
spawn gpg -o "${pkg}.sig" -b "${pkg}"
expect {
"Enter passphrase:" {
					send "${GPG_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done
popd
}
;;
	sources)
# signature for source packages
[ "${type}" == "sources" ] && [ -d artifacts/${PACMAN_REPOSITORY_NAME}/sources ] && {
pushd artifacts/${PACMAN_REPOSITORY_NAME}/sources
for pkg in *.src.tar.gz; do
expect << _EOF
spawn gpg -o "${pkg}.sig" -b "${pkg}"
expect {
"Enter passphrase:" {
					send "${GPG_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done
popd
}
;;
	*)
	echo "Unknown package type '${type}'."
;;
esac
# End for type in ${all_types[@]}; do
done
export LANG=${LANG_bkp}
}

# Make MSYS2 to use custom repository
set_repository_mirror()
{
[[ "${DEPLOY_PROVIDER}" = bintray ]] || return 1
local mirrorlist="$(cygpath ${1}/etc/pacman.d/mirrorlist.msys)"
local pacmanconf="$(cygpath ${1}/etc/pacman.conf)"
local REMOTE_REPOSITORY_PATH="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${ARCH}"
local LOCAL_REPOSITORY_PATH="${PWD}/artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}"

[ -f ${mirrorlist}.orig ] || mv -vf ${mirrorlist}{,.orig}

touch ${mirrorlist}

[ -f "${LOCAL_REPOSITORY_PATH}/${PACMAN_REPOSITORY_NAME}.db" ] && {
(grep -q "Server = file://${LOCAL_REPOSITORY_PATH}" ${mirrorlist}) || sed -i "1iServer = file://${LOCAL_REPOSITORY_PATH}" ${mirrorlist}
true
} || {
(grep -q "Server = file://${LOCAL_REPOSITORY_PATH}" ${mirrorlist}) && sed -i "s|Server = file://${LOCAL_REPOSITORY_PATH}||g" ${mirrorlist}
}

(grep -q "Server = ${REMOTE_REPOSITORY_PATH}" ${mirrorlist}) || echo "Server = ${REMOTE_REPOSITORY_PATH}" >> ${mirrorlist}

cp -vf ${pacmanconf}{,.orig}
sed -i -r "s/^\s*(Architecture =).*/\1 ${ARCH}/g" ${pacmanconf}

return 0
}

# Restore mirror list
unset_repository_mirror()
{
local mirrorlist="$(cygpath ${1}/etc/pacman.d/mirrorlist.msys)"
local pacmanconf="$(cygpath ${1}/etc/pacman.conf)"
[ -f "${mirrorlist}.orig" ] && mv -vf ${mirrorlist}{.orig,}
[ -f "${pacmanconf}.orig" ] && mv -vf ${pacmanconf}{.orig,}
}

# Build packages
build_packages()
{
[ ${#packages[@]} == 0 ] && return 0
mkdir -pv artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/
mkdir -pv artifacts/${PACMAN_REPOSITORY_NAME}/sources/
for package in "${packages[@]}"; do
    execute 'Building binary' makepkg --noconfirm --skippgpcheck --nocheck --syncdeps --rmdeps --cleanbuild
    execute 'Building source' makepkg --noconfirm --skippgpcheck --allsource
	execute 'Installing' yes:pacman --noprogressbar --upgrade *.pkg.tar.xz
    (ls "${package}"/*.pkg.tar.xz &>/dev/null) && {
	mv "${package}"/*.pkg.tar.xz artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/
	( source ${package}/PKGBUILD; echo ${pkgname[@]} ${provides[@]} | tr ' ' '\n'; ) >> artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/packages.list
	}
    (ls "${package}"/*.src.tar.gz &>/dev/null) && mv "${package}"/*.src.tar.gz artifacts/${PACMAN_REPOSITORY_NAME}/sources/
    unset package
done
}

# Create remote repository
create_remote_repository()
{
local API=https://api.bintray.com
local resp data

resp="$(curl --silent -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X GET ${API}/repos/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY})"
[ "${resp}" == "{\"message\":\"Repo '${BINTRAY_REPOSITORY}' was not found\"}" ] && {
# Create Repository
echo "Creating repository: ${BINTRAY_REPOSITORY}"
data="{
  \"name\": \"${BINTRAY_REPOSITORY}\",
  \"type\": \"generic\",
  \"private\": false,
  \"desc\": \"MSYS2 packages for Windows XP.\",
  \"labels\":[\"MSYS2\", \"Windows XP\"],
  \"gpg_sign_metadata\": false,
  \"gpg_sign_files\":false,
  \"gpg_use_owner_key\":false
}"
resp=$(curl -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST "${API}/repos/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}" -d "${data}" -H "Content-Type: application/json")
(grep -q "\"name\":\"${BINTRAY_REPOSITORY}\"" <<< ${resp}) &&
(grep -Pq "\"owner\":\"${BINTRAY_ACCOUNT}\"" <<< ${resp}) &&
echo "Done" || echo "Failed"
}

resp="$(curl --silent -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X GET ${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME})"
[ "${resp}" == "{\"message\":\"Package '${DISTRIB_PACKAGE_NAME}' was not found\"}" ] && {
# Create package ${DISTRIB_PACKAGE_NAME}
echo "Creating package: ${DISTRIB_PACKAGE_NAME}"
data="{
  \"name\": \"${DISTRIB_PACKAGE_NAME}\",
  \"desc\": \"MSYS2 base packages\",
  \"labels\": [\"MSYS2\", \"Windows\"],
  \"licenses\": [\"GPL-3.0\"],
  \"vcs_url\": \"$(git remote get-url origin | sed 's/\.git$//')/tree/$(git symbolic-ref --short HEAD)\",
  \"issue_tracker_url\": \"https://gitee.com/atomlong/MSYS2-packages/issues\",
  \"public_download_numbers\": false,
  \"public_stats\": true
}"
resp=$(curl -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST "${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}" -d "${data}" -H "Content-Type: application/json")
(grep -q "\"name\":\"${DISTRIB_PACKAGE_NAME}\"" <<< ${resp}) &&
(grep -q "\"repo\":\"${BINTRAY_REPOSITORY}\"" <<< ${resp}) &&
(grep -q "\"owner\":\"${BINTRAY_ACCOUNT}\"" <<< ${resp}) &&
echo "Done" || echo "Failed"
}

resp="$(curl --silent -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X GET "${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/versions/${BINTRAY_VERSION}")"
[ "${resp}" == "{\"message\":\"Version '${BINTRAY_VERSION}' was not found\"}" ] && {
# Create version in package ${DISTRIB_PACKAGE_NAME}
echo "Create package '${DISTRIB_PACKAGE_NAME}' version: ${BINTRAY_VERSION}"
data="{
  \"name\": \"${BINTRAY_VERSION}\"
}"
resp=$(curl -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST "${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/versions" -d "${data}" -H "Content-Type: application/json")
(grep -q "\"name\":\"${BINTRAY_VERSION}\"" <<< ${resp}) &&
(grep -q "\"package\":\"${DISTRIB_PACKAGE_NAME}\"" <<< ${resp}) &&
(grep -q "\"repo\":\"${BINTRAY_REPOSITORY}\"" <<< ${resp}) &&
(grep -q "\"owner\":\"${BINTRAY_ACCOUNT}\"" <<< ${resp}) &&
echo "Done" || echo "Failed"
}

resp="$(curl --silent -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X GET ${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME})"
[ "${resp}" == "{\"message\":\"Package '${PACMAN_REPOSITORY_NAME}' was not found\"}" ] && {
# Create package ${PACMAN_REPOSITORY_NAME}
echo "Creating package: ${PACMAN_REPOSITORY_NAME}"
data="{
  \"name\": \"${PACMAN_REPOSITORY_NAME}\",
  \"desc\": \"MSYS2 packages\",
  \"labels\": [\"MSYS2\", \"Windows\"],
  \"licenses\": [\"GPL-3.0\"],
  \"vcs_url\": \"$(git remote get-url origin | sed 's/\.git$//')/tree/$(git symbolic-ref --short HEAD)\",
  \"issue_tracker_url\": \"https://gitee.com/atomlong/MSYS2-packages/issues\",
  \"public_download_numbers\": false,
  \"public_stats\": true
}"
resp=$(curl -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST "${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}" -d "${data}" -H "Content-Type: application/json")
(grep -q "\"name\":\"${PACMAN_REPOSITORY_NAME}\"" <<< ${resp}) &&
(grep -q "\"repo\":\"${BINTRAY_REPOSITORY}\"" <<< ${resp}) &&
(grep -q "\"owner\":\"${BINTRAY_ACCOUNT}\"" <<< ${resp}) &&
echo "Done" || echo "Failed"
}

resp="$(curl --silent -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X GET "${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/versions/${BINTRAY_VERSION}")"
[ "${resp}" == "{\"message\":\"Version '${BINTRAY_VERSION}' was not found\"}" ] && {
# Create version in package ${PACMAN_REPOSITORY_NAME}
echo "Create package '${PACMAN_REPOSITORY_NAME}' version: ${BINTRAY_VERSION}"
data="{
  \"name\": \"${BINTRAY_VERSION}\"
}"
resp=$(curl -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST "${API}/packages/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/versions" -d "${data}" -H "Content-Type: application/json")
(grep -q "\"name\":\"${BINTRAY_VERSION}\"" <<< ${resp}) &&
(grep -q "\"package\":\"${PACMAN_REPOSITORY_NAME}\"" <<< ${resp}) &&
(grep -q "\"repo\":\"${BINTRAY_REPOSITORY}\"" <<< ${resp}) &&
(grep -q "\"owner\":\"${BINTRAY_ACCOUNT}\"" <<< ${resp}) &&
echo "Done" || echo "Failed"
}

}

# Get the checksum of one file on the server.
remote_file_sha1()
{
[ $# == 2 ] || { echo "Usage: remote_file_sha1 <type> <file>"; return 1; }
local type="${1}" file="${2}"
local download_link

case ${type} in
	distrib) download_link="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${ARCH}/${file}";;
	binary) download_link="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${ARCH}/${file}";;
	sources) download_link="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/sources/${file}";;
esac

wget --server-response --spider "${download_link}" 2>&1 | grep -Pio "Sha1:\s*\K\w+"
return 0
}

# Delete one or more files on the server.
remote_file_delete()
{
(( $# >= 2 )) || { echo "Usage: remote_file_delete <type> <filelist>"; return 1; }
local type="${1}"
shift
local filelist=(${@})
local file resp remote_dir

case ${type} in
	distrib) remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${ARCH};;
	binary) remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${ARCH};;
	sources) remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/sources;;
	*)
		echo "Unknown type '${type}'."
		return 2;
		;;
esac

for file in ${filelist[@]}; do
resp=$(curl --silent --show-error --connect-timeout 5 --retry 10 -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X DELETE ${remote_dir}/${file})
[ "${resp}" == '{"message":"success"}' ] && echo "Deleted BinTray file ${file}"
done
}

# Delete old files on the server.
remote_clean_up()
{
local pkglist=artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}/old_pkg.list
local pkg
[ -f "${pkglist}" ] && {
while read pkg; do
remote_file_delete binary ${pkg}-{${ARCH},any}.pkg.tar.xz{,.sig}
remote_file_delete sources ${pkg}.src.tar.gz{,.sig}
done < ${pkglist}
rm -vf ${pkglist}
}
}

# Deplay package
deploy_packages()
{
[ $# == 1 ] || { echo "Usage: deploy_packages <type>"; return 1; }
local type="${1}"
local pkg resp local_dir remote_dir remote_publish checksum filelist

case ${type} in
	distrib) local_dir=artifacts/${DISTRIB_PACKAGE_NAME}/${ARCH}
			 remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${BINTRAY_VERSION}/${DISTRIB_PACKAGE_NAME}/${ARCH}
			 remote_publish=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/distrib/latest/publish
			 ;;
	binary)	 local_dir=artifacts/${PACMAN_REPOSITORY_NAME}/${ARCH}
			 remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_VERSION}/${PACMAN_REPOSITORY_NAME}/${ARCH}
			 remote_publish=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_VERSION}/publish
			 ;;
	sources) local_dir=artifacts/${PACMAN_REPOSITORY_NAME}/sources
			 remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_VERSION}/${PACMAN_REPOSITORY_NAME}/sources
			 remote_publish=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_VERSION}/publish
			 ;;
		*)
			echo "Unknown package type '${type}'."
			return 2
			;;
esac

[ -d "${local_dir}" ] || return 1;

pushd ${local_dir}
[ "${type}" == binary ] && {
filelist=($(ls | grep -v "^old_pkg.list$" | grep -v "^packages.list$" | grep -Pv "${PACMAN_REPOSITORY_NAME}"'\.(db|file)(\.tar\.xz(\.old)?)?') $(ls | grep -P "${PACMAN_REPOSITORY_NAME}"'\.(db|file)(\.tar\.xz(\.old)?)?'))
} || {
filelist=($(ls))
}

for pkg in ${filelist[@]}; do
[ "${type}" == binary ] && {
checksum=$(grep -Po '.*(?=-\w+\.pkg\.tar\.xz$)' <<< ${pkg})
[ -f old_pkg.list ] && [ -n "${checksum}" ] && sed -i -r "/${checksum}/d" old_pkg.list
}
checksum="$(remote_file_sha1 "${type}" "${pkg}")"
[ "${checksum}" == "$(sha1sum ${pkg} | cut -d ' ' -f1)" ] && { echo "File '${pkg}' already exists on the server."; continue; }
[ -n "${checksum}" ] && remote_file_delete "${type}" "${pkg}"
printf "Uploading ${pkg} ...... \n"
resp=""
while ! ( [ "${resp}" == '{"message":"success"}' ] || (grep -Pq "Unable to upload files: An artifact with the path '[^']+' already exists" <<< ${resp}) ); do
resp=$(curl --progress-bar -T "${pkg}" -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} ${remote_dir}/${pkg})
done
done
popd

printf "Publishing ${type} packages ...... \n"
resp=$(curl --silent --show-error -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST ${remote_publish})
resp=$(grep -Po "{\"files\":\K\d+(?=})" <<< ${resp})
printf "Published ${resp} new files.\n"
}

# deploy artifacts
deploy_artifacts()
{
create_remote_repository
deploy_packages binary
deploy_packages sources
deploy_packages distrib
remote_clean_up
}
