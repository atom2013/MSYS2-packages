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

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
    cd "${package:-.}"
    message "${status}"
    if [[ "${command}" != *:* ]]
        then ${command} ${arguments[@]}
        else ${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
    cd - > /dev/null
}

# Update system
update_system() {
    pacman --sync --refresh --sysupgrade --sysupgrade --noconfirm
}

# 函数： 添加软件包到仓库数据库
# Usage: repository_add_package	<pkgball> [pkgball ...]
# 参数：
# <pkgball>		软件包文件名称，比如gcc-6.3.0-1-i686.pkg.tar.xz
# 备注：
# (1) 指定的软件包必须事先存放在${PACMAN_LOCAL_REPOSITORY}/${arch}目录下
repository_add_package()
{
[ $# == 0 ] && { echo "Usage: repository_add_package	<pkgball> [pkgball ...]"; return 1; }
local pkgnames
local pkg

pkgnames=()
for pkg in ${@}; do
[ -f ${PACMAN_LOCAL_REPOSITORY}/${arch}/${pkg} ] && pkgnames+=(${pkg})
done
[ ${#pkgnames[@]} == 0 ] || {
local LANG_bkp=${LANG}
export LANG=en_US.UTF-8

pushd ${PACMAN_LOCAL_REPOSITORY}/${arch}
while [ -f ${PACMAN_REPOSITORY_NAME}.db.tar.xz.lck ]; do
true
done

repo-add "${PACMAN_REPOSITORY_NAME}.db.tar.xz" ${pkgnames[@]} | tee /dev/stderr | grep -Po "\bRemoving existing entry '\K[^']+(?=')" >> old_pkg.list
popd

export LANG=${LANG_bkp}
}
}

# 函数： 仓库数据库中删除软件包
# Usage: repository_remove_package	<pkgball> [pkgball ...]
# 参数：
# <pkgball>		软件包文件名称，比如gcc-6.3.0-1-i686.pkg.tar.xz
repository_remove_package()
{
[ $# == 0 ] && { echo "Usage: repository_remove_package	<pkgball> [pkgball ...]"; return 1; }
local pkgnames
local pkg

pkgnames=()
for pkg in ${@}; do
[[ "${pkg}" != *.pkg.tar.xz ]] || pkgnames+=($(grep -Po '^\w+(-devel)?' <<< ${pkg}))
done
[ ${#pkgnames[@]} == 0 ] || {
pushd ${PACMAN_LOCAL_REPOSITORY}/${arch}
repo-remove "${PACMAN_REPOSITORY_NAME}.db.tar.xz" ${pkgnames[@]}
pacman --sync --refresh
popd
}
}

# 函数：检查某个URL是否存在
# Usage: check_url_exist <url>
# 如果url存在，则打印yes；
# 如果url不存在，则打印no
check_url_exist()
{
local url="${1}"

# if (curl --connect-timeout 60 --retry 10 --location --range 0-0 --fail --silent --output /dev/null "${url}"); then
if (wget --timeout=60 --spider --output-file=/dev/null "${url}" ); then
  echo "yes"
else
  echo "no"
fi
}

# 检查服务器是否已经有某个二进制包
# Usage: check_remote_package <type> <pkgball>
# 参数：
# type		-		包类型;可取值：distrib, binary, sources
# pkgball	-		包文件名称(含后缀)
# 如果存在，返回0；否则返回1
check_remote_package()
{
local type=${1}
shift
local pkg="${1}"
local remote_path

case ${type} in
	distrib) remote_path=${BINTRAY_DOWNLOAD_PATH}/distrib/${arch}/${pkg};;
	binary) remote_path=${BINTRAY_DOWNLOAD_PATH}/${PACMAN_REPOSITORY_NAME}/${arch}/${pkg};;
	sources) remote_path=${BINTRAY_DOWNLOAD_PATH}/${PACMAN_REPOSITORY_NAME}/sources/${pkg};;
esac
[ "$(check_url_exist ${remote_path})" == "yes" ] && return 0
return 1
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
	distrib) remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${arch};;
	binary) remote_dir=https://api.bintray.com/content/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${arch};;
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

# 函数： 查询服务器上某个文件的sha1
remote_file_sha1()
{
[ $# == 2 ] || { echo "Usage: remote_file_sha1 <type> <file>"; return 1; }
local type="${1}" file="${2}"
local download_link

case ${type} in
	distrib) download_link="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${arch}/${file}";;
	binary) download_link="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${arch}/${file}";;
	sources) download_link="https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/sources/${file}";;
esac

wget --server-response --spider "${download_link}" 2>&1 | grep -Pio "Sha1:\s*\K\w+"
return 0
}

# 函数： 下载软件包到本地仓库
# Usage: download_package	<type> <pkgball> [pkgball ...]
# <type>		包类型; 可取值：distrib, binary, sources
# <pkgball>		软件包文件名称，比如gcc-6.3.0-1-i686.pkg.tar.xz
download_package()
{
(( $# < 2 )) && { echo "Usage: download_package <type> <pkgball> [pkgball ...]"; return 1; }
local type="${1}"
shift
local pkgnames=(${@})
local pkg local_dir local_path remote_dir remote_path remote_publish checksum

case ${type} in
	distrib) local_dir=${PACMAN_LOCAL_REPOSITORY}/../distrib/${arch}
			 remote_dir=https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${DISTRIB_PACKAGE_NAME}/${arch}
			 remote_publish=${BINTRAY_API_DIR}/distrib/latest/publish
			;;
	binary)	local_dir=${PACMAN_LOCAL_REPOSITORY}/${arch}
			remote_dir=https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/${arch}
			remote_publish=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/publish
			;;
	sources) local_dir=${PACMAN_LOCAL_REPOSITORY}/sources
			 remote_dir=https://dl.bintray.com/${BINTRAY_ACCOUNT}/${BINTRAY_REPOSITORY}/${PACMAN_REPOSITORY_NAME}/sources
			 remote_publish=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/publish
			;;
esac

for pkg in ${pkgnames[@]}; do
checksum="$(remote_file_sha1 ${type} ${pkg})"
[ -n "${checksum}" ] || { echo "No file '${pkg}' on the server."; continue; }
local_path=${local_dir}/${pkg}
remote_path=${remote_dir}/${pkg}

[ -f "${local_path}" ] && {
[ "${checksum}" == "$(sha1sum ${local_path} | cut -d ' ' -f1)" ] && continue || rm -f "${local_path}" 
}

printf "Downloading ${pkg} ...... \n"
curl --progress-bar -fSL -o "${local_path}" "${remote_path}" || { echo "Failed to donwload '${pkg}'"; rm -f "${local_path}"; }
done
}

# 函数： 上传软件包到远程仓库
# Usage: upload_package	<type> <pkgball> [pkgball ...]
# 参数： 
# <type>		包类型; 可取值：distrib, binary, sources
# <pkgball>		软件包文件名称，比如gcc-6.3.0-1-i686.pkg.tar.xz
upload_package()
{
(( $# < 2 )) && { echo "Usage: upload_package <type> <pkgball> [pkgball ...]"; return 1; }
local type="${1}"
shift
local pkgnames=(${@})
local pkg resp local_dir local_path remote_dir remote_path remote_publish checksum

case ${type} in
	distrib) local_dir=${PACMAN_LOCAL_REPOSITORY}/../distrib/${arch}
			 remote_dir=${BINTRAY_API_DIR}/distrib/latest/distrib/${arch}
			 remote_publish=${BINTRAY_API_DIR}/distrib/latest/publish
			;;
	binary)	local_dir=${PACMAN_LOCAL_REPOSITORY}/${arch}
			remote_dir=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/${PACMAN_REPOSITORY_NAME}/${arch}
			remote_publish=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/publish
			;;
	sources) local_dir=${PACMAN_LOCAL_REPOSITORY}/sources
			 remote_dir=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/${PACMAN_REPOSITORY_NAME}/sources
			 remote_publish=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/publish
			;;
	*)	echo "Unknwon package type ${type}"
		return 1
		;;
esac

for pkg in ${pkgnames[@]}; do
local_path=${local_dir}/${pkg}
[ -f "${local_path}" ] || { echo "No file ${pkg} in local repository."; continue; }
[ "${type}" == binary ] && {
checksum=$(grep -Po '.*(?=-\w+\.pkg\.tar\.xz$)' <<< ${pkg})
[ -f ${PACMAN_LOCAL_REPOSITORY}/${arch}/old_pkg.list ] && [ -n "${checksum}" ] && sed -i -r "/${checksum}/d" ${PACMAN_LOCAL_REPOSITORY}/${arch}/old_pkg.list
}
checksum="$(remote_file_sha1 ${type} ${pkg})"
[ "${checksum}" == "$(sha1sum ${local_path} | cut -d ' ' -f1)" ] && { echo "File '${pkg}' already exists on the server."; continue; }
[ -n "${checksum}" ] && remote_file_delete "${type}" "${pkg}"
printf "Uploading ${pkg} ...... \n"
remote_path=${remote_dir}/${pkg}
resp=""
while ! ( [ "${resp}" == '{"message":"success"}' ] || (grep -Pq "Unable to upload files: An artifact with the path '[^']+' already exists" <<< ${resp}) ); do
resp=$(curl --progress-bar -T "${local_path}" -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} ${remote_path})
done
done

printf "Publishing ${type} package  ...... \n"
resp=$(curl --silent --show-error  -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST ${remote_publish})
resp=$(grep -Po "{\"files\":\K\d+(?=})" <<< ${resp})
printf "${resp} new files published.\n"
}

# 函数： 上传所有包
# Usage: upload_all_packages <type>
# 参数： 
# <type>		包类型; 可取值：distrib, binary, sources
upload_all_packages()
{
[ $# == 1 ] || { echo "Usage: upload_all_packages <type>"; return 1; }
local type="${1}"
local pkg resp local_dir local_path remote_dir remote_path remote_publish checksum

case ${type} in
	distrib) local_dir=${PACMAN_LOCAL_REPOSITORY}/../distrib/${arch}
			 remote_dir=${BINTRAY_API_DIR}/distrib/latest/distrib/${arch}
			 remote_publish=${BINTRAY_API_DIR}/distrib/latest/publish
			 ;;
	binary)	 local_dir=${PACMAN_LOCAL_REPOSITORY}/${arch}
			 remote_dir=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/${PACMAN_REPOSITORY_NAME}/${arch}
			 remote_publish=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/publish
			 ;;
	sources) local_dir=${PACMAN_LOCAL_REPOSITORY}/sources
			 remote_dir=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/${PACMAN_REPOSITORY_NAME}/sources
			 remote_publish=${BINTRAY_API_DIR}/${PACMAN_REPOSITORY_NAME}/${BINTRAY_PACKAGE_VERSION}/publish
			 ;;
esac

pushd ${local_dir}
for pkg in $(ls); do
local_path=${local_dir}/${pkg}
remote_path=${remote_dir}/${pkg}
checksum="$(remote_file_sha1 ${type} ${pkg})"
[ "${checksum}" == "$(sha1sum ${local_path} | cut -d ' ' -f1)" ] && { echo "File '${pkg}' already exists on the server."; continue; }
[ -n "${checksum}" ] && remote_file_delete "${type}" "${pkg}"
printf "\n\nuploading ${pkg} ...... \n"
resp=""
while ! ( [ "${resp}" == '{"message":"success"}' ] || (grep -Pq "Unable to upload files: An artifact with the path '[^']+' already exists" <<< ${resp}) ); do
resp=$(curl -T "${local_path}" -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} ${remote_path})
done
printf "Done\n"
done
popd

printf "Publishing ${type} package ...... \n"
resp=$(curl -u${BINTRAY_ACCOUNT}:${BINTRAY_API_KEY} -X POST ${remote_publish})
resp=$(grep -Po "{\"files\":\K\d+(?=})" <<< ${resp})
printf "\n${resp} files published.\n"
}

# 函数：上传整个本地仓库
# Usage: upload_repository
upload_repository()
{
upload_all_packages distrib
upload_all_packages binary
upload_all_packages sources
}

# Delete old files on the server.
remote_clean_up()
{
local pkglist=${PACMAN_LOCAL_REPOSITORY}/${arch}/old_pkg.list
local pkg
[ -f "${pkglist}" ] && {
while read pkg; do
remote_file_delete binary ${pkg}-{${ARCH},any}.pkg.tar.xz{,.sig}
pkg=$(sed -r 's/-devel-/-/' <<< ${pkg})
pkg=(${pkg}.src.tar.gz{,.sig}  $(sed -r -e 's/^lib//' -e 's/^python(3|2)/python/' <<< ${pkg}).src.tar.gz{,.sig})
remote_file_delete sources $(echo ${pkg[@]} | tr ' ' '\n' | sort -u)
done < ${pkglist}
rm -vf ${pkglist}
}
}

# 函数： 签名软件包
# Usage: sign_package <type> <pkgball> [pkgball ...]
# 参数：
# <pkgname-ver>		软件包文件名称，比如gcc-6.3.0-1-i686.tar.xz
# 备注：
# (1) 指定的软件包必须事先存放在${PACMAN_LOCAL_REPOSITORY}/${arch}目录下
sign_package()
{
(( $# < 2 )) && { echo "Usage: sign_package <type> <pkgball> [pkgball ...]"; return 1; }
[ -n "${GPG_KEY_PASSWD}" ] || { echo "You must set GPG_KEY_PASSWD firstly."; return 1; } 
local type=${1}
shift
local pkgnames=(${@})
local pkg pkgpath
local LANG_bkp=${LANG}

export LANG=en_US.UTF-8

for pkg in ${pkgnames[@]}; do
case ${type} in
	distrib) pkgpath="${PACMAN_LOCAL_REPOSITORY}/../distrib/${arch}/${pkg}";;
	binary)  pkgpath="${PACMAN_LOCAL_REPOSITORY}/${arch}/${pkg}";;
	sources) pkgpath="${PACMAN_LOCAL_REPOSITORY}/sources/${pkg}";;
	*) echo "Unknown package type ${type}"
	   return 1
	   ;;
esac
[ ! -f "${pkgpath}" ] || {
# signature for binary package.
expect << _EOF
spawn gpg --pinentry-mode loopback -o "${pkgpath}.sig" -b "${pkgpath}"
expect {
"Enter passphrase:" {
					send "${GPG_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
}
done

export LANG=${LANG_bkp}
}

# 函数：为所有的软件包生成签名文件
# Usage: sign_all_packages
# 备注：
# (1) 所有软件包放在${PACMAN_LOCAL_REPOSITORY}/${arch}目录下
sign_all_packages()
{
[ -n "${GPG_KEY_PASSWD}" ] || { echo "You must set GPG_KEY_PASSWD firstly."; return 1; } 
local f
local LANG_bkp=${LANG}
export LANG=en_US.UTF-8

for f in $(ls ${PACMAN_LOCAL_REPOSITORY}/${arch}/*.pkg.tar.xz); do
# signature for binary package.
expect << _EOF
spawn gpg --pinentry-mode loopback -o "${f}.sig" -b "${f}"
expect {
"Enter passphrase:" {
					send "${GPG_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done

for f in $(ls ${PACMAN_LOCAL_REPOSITORY}/sources/*.src.tar.gz); do
# signature for source package
expect << _EOF
spawn gpg --pinentry-mode loopback -o "${f}.sig" -b "${f}"
expect {
"Enter passphrase:" {
					send "${GPG_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done

export LANG=${LANG_bkp}
}

# 函数： 读取用户输入的密码信息
# Usage: Read_Passwd <varname>
Read_Passwd()
{
[ $# == 1 ] || { echo "Usage: Read_Passwd <varname>"; return 1; }
local char
local varname=${1}
local password=''

while IFS= read -r -s -n1 char; do
  [[ -z $char ]] && { printf '\n'; break; } # ENTER pressed; output \n and break.
  if [[ $char == $'\x7f' ]]; then # backspace was pressed
      # Remove last char from output variable.
      [[ -n $password ]] && password=${password%?}
      # Erase '*' to the left.
      printf '\b \b'
  else
    # Add typed char to output variable.
    password+=$char
    # Print '*' in its stead.
    printf '*'
  fi
done
eval ${varname}=${password}
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; exit 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; exit 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }

# 函数：比较版本号大小
# Usage: CT_CompareVerNo <VerNo1> <Operate> <VerNo2>
# 如果版本号比较结果为真，则返回0；否则返回1
# 举例： 
# CompareVerNo "1.1.0c" ">=" "1.0.1j" # 返回0
# CompareVerNo "1.18" ">=" "1.9" # 返回0
# CompareVerNo "4.4.39" ">=" "4.4" # 返回0
# 备注：
# (1) 假定版本号各字段之间以点号'.'分割
# (2) 两个版本号的字段数目可以不等
CompareVerNo()
{
local V1=${1}
local Op=${2}
local V2=${3}
local V1F
local V2F
local VL
local i

[ "${V1}" ] && [ "${V2}" ] || { echo "Usage: CompareVerNo <VerNo1> <Operate> <VerNo2>"; return 1; }

V1F=($(sed 's|\.| |g' <<< ${V1}))
V2F=($(sed 's|\.| |g' <<< ${V2}))

((${#V1F[*]} > ${#V2F[*]})) && VL=${#V1F[*]} || VL=${#V2F[*]}
for ((i=0; i<VL; i++)); do
((${#V1F[i]} > ${#V2F[i]})) && V2F[i]=$(printf '0%.0s' {1..$((${#V1F[i]}-${#V2F[i]}))})${V2F[i]}
((${#V1F[i]} < ${#V2F[i]})) && V1F[i]=$(printf '0%.0s' {1..$((${#V2F[i]}-${#V1F[i]}))})${V1F[i]}
done

i=0
while ((i < VL)); do
[ "${V1F[i]}" != "${V2F[i]}" ] && break
((i=i+1))
done

if ((i >= VL)); then
case "${Op}" in
	 ">") exit 1;;
	">=") exit 0;;
	"==") exit 0;;
	"<=") exit 0;;
	 "<") exit 1;;
	"!=") exit 1;;
	 *) echo "Unknown operate ${Op}"
	 exit 1
	 ;;
esac
else
case "${Op}" in
	 ">") [ "${V1F[i]}" \> "${V2F[i]}"];;
	">=") [ "${V1F[i]}" \> "${V2F[i]}" -o "${V1F[i]}" == "${V2F[i]}" ];;
	"==") [ "${V1F[i]}" == "${V2F[i]}" ];;
	"<=") [ "${V1F[i]}" \< "${V2F[i]}" -o "${V1F[i]}" == "${V2F[i]}" ];;
	 "<") [ "${V1F[i]}" \< "${V2F[i]}" ];;
	"!=") [ "${V1F[i]}" != "${V2F[i]}" ];;
	 *) echo "Unknown operate ${Op}"
	 exit 1
	 ;;
esac
fi

exit $?
}

# 函数：替换变量
# Usage: replace_variable <var_file> <str1> [str2] ...
# 参数：
# <var_file>		:	包含变量定义的文件
# <str1>			:	包含变量的字符串
replace_variable()
{
[ $# == 0 ] && { echo "Usage: replace_variable <var_file> <str1> [ str2 ] "; return 1; }
[ $# == 1 ] && return 0

local var_file=${1}
shift
local strs=(${@})
local varinname=($(grep -Po '\$\{?\K\w+' <<< ${strs[@]} | sort -u))
local var val

[ -f ${var_file} ] || return 1

for var in ${varinname[@]}; do
val=$(grep -Po "^\s*(${var}=\K[^\(\)#]*|${var}=\(\K[^\(\)#]+(?=\)))" ${var_file} | sed -r -e "s/'//g" -e "s/\"//g" -e "s/\\\$\{?${var}(\[@\])?\}?//g") # 最后一个sed表达式防止变量引用自身
[ -n "${val}" ] || {
val=($(sed -rn "/${var}=\([^\)]*$/,/[^\(]*\).*$/p" ${var_file} | sed -r 's/#.*//g' | grep -Po '\b((?!'${var}'=)[^\(\)#])+\b')) # 第2个sed命令用于删除注释
[ ${#val[@]} == 0 ] && continue
}

eval local ${var}=\(${val[@]}\) # FIXME: ${var}变量可能已经在本函数内定义过了。
unset var val
done

eval echo ${strs[@]}
}

# 函数： 文件内容中变量替换
# Usage: replace_file_variable <file> <pattern_1> [pattern_2]
# 参数：
# <file>		Shell脚本文件
# <pattern_1>	行匹配模式
# 描述：
# 在<file>中查找匹配<pattern_1>的行，对其中的变量进行替换,替换值从<file>文件中搜索
# 变量替换结束后，打印<file>全文
replace_file_variable()
{
(( $# >= 2 )) || { echo "Usage: replace_file_variable <file>"; return 1; }
local file=${1}
shift
local pattern=(${@})
local varnames
local var val exp i

[ -f ${file} ] || return 1

for (( i=0; i<${#pattern[@]}; i++ )); do
var=($(sed -rn "/${pattern[i]}/p" ${file} | grep -Po '\$\{?\K\w+' || true))
[ ${#var[@]} == 0 ] && unset pattern[i] || varnames+=(${var[@]})
done
pattern=(${pattern[@]})
varnames=($(echo ${varnames[@]} | tr ' ' '\n' | sort -u))

for var in ${varnames[@]}; do
val=$(grep -Po "^\s*${var}=\K[^#]*" ${file} | sed -e "s/'//g" -e "s/\"//g")
[ -n "${val}" ] && {
for ((i=0; i<${#pattern[@]}; i++)); do
exp+=" -e '/${pattern[i]}/{s|\\\$\{${var}\}|${val}|g}' -e '/${pattern[i]}/{s|\\\$${var}|${val}|g}'"
done
}
done

[ -n "${exp}" ] && eval sed -r ${exp} ${file} || cat ${file}
}


# 列出所有的组
# Usage: list_allgroups
list_allgroups()
{
local pkgbuild grp groups

groups=()

for pkgbuild in $(find -maxdepth 2 -mindepth 2 -type f -name PKGBUILD); do
grp=($(grep -Po "^\s*groups=\(\K[^\)]+" ${pkgbuild}))
groups+=($(replace_variable ${pkgbuild} ${grp[@]}))
done

echo ${groups[@]} | sed -e "s/'//g" -e "s/\"//g" | tr ' ' '\n' | sort -u
}

# 列出属于某个组的所有子目录
# Usage: list_subdir_by_group <group>
# 参数：
# <group>			软件组，比如base、libraries等，不能含有变量
list_subdir_by_group()
{
[ $# == 1 ] || { echo "Usage: list_subdir_by_group <group>"; return 1; }
local group=${1}
local grps
local pkgbuild subdirs

subdirs=()

for pkgbuild in $(find -maxdepth 2 -mindepth 2 -type f -name PKGBUILD); do
grps=($(grep -Po '^\s*groups=\(\K[^\)]+' ${pkgbuild} | sed -e "s/'//g" -e "s/\"//g"))
grps=($(replace_variable ${pkgbuild} ${grps[@]}))
(grep -Pq "(?<=^|\s)${group}(?=$|\s)" <<< ${grps[@]}) && {
subdirs+=($(grep -Po '[^/]+(?=/PKGBUILD)' <<< ${pkgbuild}))
}
unset grps
done

echo ${subdirs[@]}
}

# 列出属于某个子目录的所有包
# Usage: list_pkgs_by_subdir <subdir>
# 比如：
# list_pkgs_by_subdir gcc
# 将会打印gcc、gcc-libs、gcc-fortran
list_pkgs_by_subdir()
{
[ $# == 1 ] || { echo "Usage: list_pkgs_by_subdir <subdir>"; return 1; }
local subdir=${1}
[ -f ${subdir}/PKGBUILD ] || return 0
local pkg_name=($(grep -Pao "^\s*(pkgname=|provides=)\(?\K[^\)#]+" ${subdir}/PKGBUILD | sed -e "s/'//g" -e "s/\"//g"))
# ${pkg_name}可能含有变量
pkg_name=($(replace_variable ${subdir}/PKGBUILD ${pkg_name[@]}))

echo ${pkg_name[@]}
}

# 检查某个包所属的组
# Usage: group_of_pkg <subdir> <pkg_name>
# 参数：
# <subdir>		软件包所属的子目录，通常是该软件包的pkgbase；比如软件包gcc-libs的pkgbase是gcc，软件包gettext-devel的pkgbase是gettext
# <pkg_name>		软件包名称；不能包含变量
# 比如：
# group_of_pkg gcc gcc-libs
# 将打印base
# group_of_pkg gettext gettext-devel
# 将打印development、base-devel
group_of_pkg()
{
[ $# == 2 ] || { echo "Usage: group_of_pkg <subdir> <pkg_name>"; return 1; }
local subdir=${1}
local pkg_name=${2}
local group

[ -f ${subdir}/PKGBUILD ] || return 1

group=($(sed -r -n "/^[[:space:]]*package_${pkg_name}[[:space:]]*\([[:space:]]*\)/,/^[[:space:]]*package_[^\(]+[[:space:]]*\(/p" ${subdir}/PKGBUILD | grep -Po "^\s*groups=\(\K[^\)]+"))

[ ${#group[@]} == 0 ] && {
group=($(sed -r -n "1,/^[[:space:]]*\w+[[:space:]]*\([[:space:]]*\)/p" ${subdir}/PKGBUILD | grep -Po "^\s*groups=\(\K[^\)]+"))
}

group=($(replace_variable "${subdir}/PKGBUILD" ${group[@]}))

echo ${group[@]} | sed -e "s/'//g" -e "s/\"//g"
}

# 检查某个软件包所在的子目录，即判断某个软件包的pkgbase
# Usage: subdir_of_pkg <pkg_name>
# 参数：
# <pkg_name>	软件包的名字，比如gettext-devel；名字中不能包含变量
# 备注：
# (1) 打印输出格式：[subdir]provider
# (2) 有些pkg_name包是由相关的provider提供的，比如sh程序包由bash包提供，libuuid包由libutil-linux包提供的。
# (3) 有些包可能有多个provider，比如mingw-w64-cross-gcc，可由mingw-w64-cross-gcc提供，也可以由mingw-w64-cross-gcc-git提供
subdir_of_pkg()
{
[ $# == 1 ] || { echo "Usage: subdir_of_pkg <pkg_name>"; return 1; }
local pkg_name=$(sed 's/+/\\+/g' <<< ${1})
local subdir provider
local pkgbuild pkgbuild_lst pkgbuild_txt pkg i

[ -f ${PACKAGES_LIST_FILE} ] && {
subdir=($(grep -Po "(?<=^\[)[^\]]+(?=\]${pkg_name}(=[\d.]+|$|\s))" ${PACKAGES_LIST_FILE}))
pkgbuild_lst=($(sed -r 's|\S+|&/PKGBUILD|g' <<< ${subdir[@]}))
} || {
pkgbuild_lst=($(find -maxdepth 2 -mindepth 2 -name "PKGBUILD" -type f))
}

subdir=()
provider=()

for pkgbuild in ${pkgbuild_lst[@]}; do
pkgbuild_txt="$(replace_file_variable ${pkgbuild} '^[[:space:]]*pkgname=' '^[[:space:]]*provides=')"
i=$(grep -Pon "^\s*(pkgname=|provides=)(.*[^-.\w])?\K${pkg_name}(?='|\"|\s|\)|$|=)" <<< "${pkgbuild_txt}" | grep -Po '^\d+(?=:)')
[ -n "${i}" ] || continue
subdir+=($(grep -Po '[^/]+(?=/PKGBUILD)' <<< ${pkgbuild}))
pkg=$(sed -rn "1,${i} s/^[[:space:]]*package_([^\(]+).*/\1/p" <<< "${pkgbuild_txt}" | tail -n 1)
[ -n "${pkg}" ] && {
provider+=(${pkg})
} || {
provider+=($(
(grep -Pq "^\s*pkgname=(.*[^-.\w])?\K${pkg_name}(?=[^-.\w]|$)" <<< "${pkgbuild_txt}") && \
echo ${pkg_name} || \
grep -Po "^\s*pkgname=([^-.\w]*)\K[-.\w]+" <<< "${pkgbuild_txt}"
))
}
unset pkgbuild_txt pkg i
done

for ((i=0; i<${#subdir[@]}; i++)); do
echo "[${subdir[i]}]${provider[i]}"
done
}

# 检查某些软件包的版本
# Usage: version_of_pkg <pkg_name>
# 参数：
# <pkg_name> 	软件包名称，比如gcc-libs、libcurl-devel等
# 备注：
# (1) 这个函数将会查找对应的PKGBUILD，从中读取pkgver和pkgrel变量，并以${pkgver}-${pkgrel}的格式打印结果
# (2) 可能有多个子目录提供相同的软件包，比如libffi和libffi-git都提供了libffi这个软件包，提供的版本分别是3.2.1-2和v3.2.1.r142.g17ffc36-2
#		对这种情况，两种版本号均打印
version_of_pkg()
{
[ $# == 1 ] || { echo "Usage: version_of_pkg <pkg_name>"; return 1; }
local pkg_name=${1}
local subdir=($(subdir_of_pkg ${pkg_name} | grep -Po '(?<=\[)[^\]]+(?=\])'))
local dir

for dir in ${subdir[@]}; do
[ -n "${subdir}" -a -f ${subdir}/PKGBUILD ] || continue
(
source ${dir}/PKGBUILD
if [ -n "${epoch}" ]; then
echo "${epoch}~${pkgver}-${pkgrel}"
else
echo "${pkgver}-${pkgrel}"
fi
) 2>/dev/null
done
}

# 列出属于某个组的所有包
# Usage: list_packages_by_group <group>
list_packages_by_group()
{
[ $# == 0 ] && echo "Usage: list_packages_by_group <group>"
local group=${1}
local pkgs pkgbuild
local grpline pkgline pkgname i j

[ -f ${GROUPS_LIST_FILE} ] && (grep -Pq -m 1 "(?<=\[${group}\])\S+" ${GROUPS_LIST_FILE}) && {
grep -Po "(?<=^\[${group}\])\S+" ${GROUPS_LIST_FILE}
return 0
}

pkgs=()

for pkgbuild in $(find -maxdepth 2 -mindepth 2 -type f -name PKGBUILD); do

grpline=($(grep -Pon '^\s*groups=\(\K[^\)]+' ${pkgbuild} | sed -e "s/'//g" -e "s/\"//g" -e "s/:/ /g" | awk '{ \
for (i=2; i<=NF; i++) { \
print $1 ":" $i " " \
} \
}'))
grpline=($(replace_variable ${pkgbuild} ${grpline[@]}))

[ "${group}" == "null" ] && [ "${#grpline[@]}" == 0 ] && {
pkgs+=($(replace_variable ${pkgbuild} $(grep -Po "^\s*pkgname=\(?\K[^\)#]+" ${pkgbuild} | sed -e "s/'//g" -e "s/\"//g")))
continue
}

grpline=($(grep -Po "\d+(?=:${group}(\s|$))" <<< ${grpline[@]}))
[ ${#grpline[@]} == 0 ] && continue

pkgline=($(grep -Pon "^\s*package_\K[^\(]+(?=\(\s*\))" ${pkgbuild}))
pkgname=($(grep -Po "\d+:\K\S+" <<< ${pkgline[@]}))
pkgline=($(grep -Po "\d+(?=:)" <<< ${pkgline[@]}))

[ ${#pkgline[@]} == 0 ] && {
pkgname=($(grep -Po "^\s*pkgname=\(?\K[^\)#]+" ${pkgbuild} | sed -e "s/'//g" -e "s/\"//g"))
pkgname=($(replace_variable ${pkgbuild} ${pkgname[@]}))
pkgs+=(${pkgname[@]})
unset pkgname
continue
}

for ((i=${#grpline[@]}-1; i>=0; i--)); do
for ((j=${#pkgline[@]}-1; j>=0; j--));do
(( ${pkgline[j]} <= ${grpline[i]} )) && break
done
((j >= 0)) && {
pkgs+=(${pkgname[j]})
unset pkgname[j] pkgline[j]
pkgname=(${pkgname[@]})
pkgline=(${pkgline[@]})
} || {
break
}
done

((i>=0)) && {
for ((j=0; j<${#pkgline[@]}; j++)); do
(sed -rn "${pkgline[j]},/^[[:space:]]*package_[^\(]+\(/p" ${pkgbuild} | grep -Pq '^\s*groups=\([^\)]+\)') && continue
pkgs+=(${pkgname[j]})
done
}

unset grpline pkgline pkgname i j
done

echo ${pkgs[@]}
}

# 函数： 获取某个软件包的依赖项
# Usage: depends_of_pkg <pkg_name>
# 参数：
# <pkg_name>		软件包名称，比如libreadline、libreadline-devel、bash-devel等
# 备注：
# (1) 软件包<pkg_name>可能由多个子目录提供，这里只采用第一个来检查其依赖
depends_of_pkg()
{
[ $# == 1 ] || { echo "Usage: depends_of_pkg <pkg_name>"; return 1; }
local pkg_name=${1}
local subdir=($(subdir_of_pkg ${pkg_name}))
local depends provider

provider=$(grep -Po '(?<=\]).*' <<< ${subdir})
subdir=$(grep -Po '(?<=\[)[^\]]+(?=\])' <<< ${subdir})
[ -n "${subdir}" -a -f ${subdir}/PKGBUILD ] || return 0

depends=($(sed -r -n "/^[[:space:]]*package_${provider}[[:space:]]*\([[:space:]]*\)/,/^[[:space:]]*package_[^\(]+[[:space:]]*\(/p" ${subdir}/PKGBUILD | grep -Po "^\s*depends\+?=\(?\K[^#\)]+"))

if [ ${#depends[@]} == 0 ]; then
depends=($(sed -r -n "1,/^[[:space:]]*\w+[[:space:]]*\([[:space:]]*\)/p" ${subdir}/PKGBUILD | grep -Po "^\s*depends=\(?\K[^#\(\)]+"))
fi

[ ${#depends[@]} == 0 ] || {
depends=($(replace_variable ${subdir}/PKGBUILD ${depends[@]}))
}

echo ${depends[@]} | sed -e "s/'//g" -e "s/\"//g" | sort -u
}

# 函数：扫描所有的软件组，记录在${GROUPS_LIST_FILE}文件中
# Usage: make_groups_list
make_groups_list()
{
local groups=($(list_allgroups))
local grp pkg

rm -f ${GROUPS_LIST_FILE}

for grp in ${groups[@]}; do
for pkg in $(list_packages_by_group ${grp}); do
echo "[${grp}]${pkg}" >> ${GROUPS_LIST_FILE}
done
done
}

# 函数： 扫描所有软件包，记录在${PACKAGES_LIST_FILE}文件中
# Usage: make_packages_list
make_packages_list()
{
local pkgbuild subdir pkg

rm -f ${PACKAGES_LIST_FILE}

for pkgbuild in $(find -mindepth 2 -maxdepth 2 -name "PKGBUILD" -type f); do
subdir=$(grep -Po '[^/]+(?=/PKGBUILD)' <<< ${pkgbuild})
for pkg in $(list_pkgs_by_subdir ${subdir});  do
echo "[${subdir}]${pkg}" >> ${PACKAGES_LIST_FILE}
done
done
}

# 编译软件包
# Usage: build_package <pkg_name>
# 备注：
# 编译软件包${pkg_name}，将编译得到的*.pkg.tar.xz安装包放到特定的目录下，但并不进行安装
build_package()
{
[ $# == 1 ] || { echo "Usage: build_package <pkg_name>"; return 1; }
local pkg_name=${1}
local packages=($(subdir_of_pkg ${pkg_name}))
local version=($(version_of_pkg ${pkg_name}))
local locfile=${PACMAN_LOCAL_REPOSITORY}/${arch}/${PACMAN_REPOSITORY_NAME}.lck

local provider=($(grep -Po '\[[^\[\]]+\]\K[^\[\]]*' <<< ${packages[@]}))
packages=($(grep -Po '(?<=\[)[^\[\]]+(?=\])' <<< ${packages[@]}))

local pkgball srcball i
local package

for ((i=0; i<${#packages[@]}; i++)); do

[[ -f ${PACMAN_LOCAL_REPOSITORY}/${arch}/${provider[i]}-${version[i]}-${arch}.pkg.tar.xz || \
   -f ${PACMAN_LOCAL_REPOSITORY}/${arch}/${provider[i]}-${version[i]}-any.pkg.tar.xz ]] && {
(grep -Pq "(?<=^|\s)${provider[i]}(?=$|\s)" <<< ${packages_builded[@]}) || packages_builded+=(${provider[i]})
[ "${pkg_name}" != "${provider[i]}" ] && ! (grep -Pq "(?<=^|\s)${pkg_name}(?=$|\s)" <<< ${packages_builded[@]}) && packages_builded+=(${pkg_name})
continue
}

while [ -f /var/lib/pacman/db.lck ]; do
true
done
update_system

package=${packages[i]}
execute 'Building binary' makepkg --noconfirm --noprogressbar --skippgpcheck --nocheck --syncdeps --rmdeps --cleanbuild
execute 'Building source' makepkg --noconfirm --noprogressbar --skippgpcheck --allsource

pkgball=($(ls "${package}"/*.pkg.tar.xz | grep -Po '[^/]+\.pkg\.tar\.xz'))
srcball=($(ls "${package}"/*.src.tar.gz | grep -Po '[^/]+\.src\.tar\.gz'))
mv "${package}"/*.pkg.tar.xz ${PACMAN_LOCAL_REPOSITORY}/${arch}
mv "${package}"/*.src.tar.gz ${PACMAN_LOCAL_REPOSITORY}/sources
rm -rf "${package}"/{src,pkg}

sign_package binary ${pkgball[@]}
sign_package sources ${srcball[@]}


echo "${pkg_name}" >> ${locfile}
while [ "$(head -n 1 ${locfile})" != "${pkg_name}" ]; do
sleep 1
done

download_package binary ${PACMAN_REPOSITORY_NAME}{.db,.files}{,.tar.xz{,.old}}
repository_add_package ${pkgball[@]}
upload_package binary ${pkgball[@]} $(sed -r 's/\S+/&.sig/g' <<< ${pkgball[@]})
upload_package sources ${srcball[@]} $(sed -r 's/\S+/&.sig/g' <<< ${srcball[@]})
upload_package binary ${PACMAN_REPOSITORY_NAME}{.db,.files}{,.tar.xz{,.old}}
remote_clean_up

while [ "$(head -n 1 ${locfile})" == "${pkg_name}" ]; do
sed -i '1d' ${locfile}
done
[ ! -s ${locfile} ] && rm -vf ${locfile}

packages_builded+=($(list_pkgs_by_subdir ${package}))
done
}

# 编译软件包依赖，但并不安装
# Usage: build_depends <pkg_name>
# 参数：
# <pkg_name>		软件包名称
build_depends()
{
[ $# == 1 ] || { echo "Usage: build_depends <pkg_name>"; return 1; }
local pkg_name=${1}
(grep -Pq "(?<=^|\s)${pkg_name}(?=$|\s)" <<< ${packages_builded[@]}) && return 0
local depends=($(depends_of_pkg ${pkg_name}))
local dep deppkg

echo "build ${pkg_name} <-- "
for dep in ${depends[@]}; do
deppkg="$(grep -Po '^[^<>=!]+' <<< ${dep})"
[ -n "${deppkg}" ] && build_depends "${deppkg}"
unset deppkg
done

echo "build --> ${pkg_name}"
build_package "${pkg_name}"
}

# 编译某些组的所有软件包
# Usage: build_group <group>
# 参数：
# <group>		软件组，比如base、base-devel、libraries、development、msys2-devel、mingw-w64-cross-toolchain等
build_group()
{
local group=${1}
local pkgs=($(list_packages_by_group ${group}))
local pkg

for pkg in ${pkgs[@]}; do
build_depends "${pkg}"
done

}

clean_build_cache()
{
export APPVEYOR_TOKEN="v2.7d9pm4w8v9j2dqlu2fq0"
curl -H "Authorization: Bearer $APPVEYOR_TOKEN" -H "Content-Type: application/json" -X DELETE https://ci.appveyor.com/api/projects/atom2013/msys2-packages/buildcache 
}

