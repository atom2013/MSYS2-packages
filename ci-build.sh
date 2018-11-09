#!/bin/bash
# MSYS2软件包自动编译脚本
# 请使用MSYS2终端执行本脚本。
# 如果要编译安装某个包，只需执行：
# ./ci-build.sh <pkg-name>
# 如果有多个软件包要编译，可以在参数中一一列出:
# ./ci-build.sh <pkg-name-1> <pkg-name-2> <pkg-name-3> 
# 也可以同时开多个窗口编译不同的软件包。

cd "$(dirname "$0")"

[ -f 'build.config' ] || {
gpg -o build.config -d build.config.gpg
}

(gpg --list-keys | grep -q 'E2A9F8CA78EDDCCC') || {
gpg -o seckey.asc -d seckey.asc.gpg
gpg --import seckey.asc
}

# Install base-devel, msys2-devel and git
(pacman -Qg base-devel &>/dev/null) || {
pacman --sync --noconfirm base-devel
}

(pacman -Qg msys2-devel &>/dev/null) || {
pacman --sync --noconfirm msys2-devel
}

(which git &>/dev/null) || {
pacman --sync --noconfirm git
}

# Configure git user
(git config --global --get user.name > /dev/null) || {
git config --global user.name "${GIT_USER_NAME}"
}

(git config --global --get user.email > /dev/null) || {
git config --global user.email "${GIT_USER_EMAIL}"
}

source 'build.config'
source 'ci-library.sh'

if [ ! -d ${PACMAN_LOCAL_REPOSITORY} ]; then
mkdir -pv ${PACMAN_LOCAL_REPOSITORY}/sources
mkdir -pv ${PACMAN_LOCAL_REPOSITORY}/${arch}
fi

for f in ${REQUIRE_PACKAGES[@]}; do
(pacman -Q ${f} &>/dev/null) || { yes | pacman -S ${f}; }
done

if [ "${GPG_KEY_PASSWD}" == "" ]; then
echo "Please input the password for gpg private key:"
Read_Passwd GPG_KEY_PASSWD
fi

[ -f ${GROUPS_LIST_FILE} ] || {
message "Creating groups list."
make_groups_list
# 注释掉某些冲突的软件包
sed -i -r \
-e 's/^\[base\]mintty-git/#&/g' \
-e 's/^\[base\]getopt/#&/g' \
-e 's/^\[mingw-w64-cross\]mingw-w64-cross-binutils-git/#&/g' \
-e 's/^\[mingw-w64-cross\]mingw-w64-cross-crt-clang-git/#&/g' \
-e 's/^\[mingw-w64-cross\]mingw-w64-cross-gcc-git/#&/g' \
${GROUPS_LIST_FILE}
}

[ -f ${PACKAGES_LIST_FILE} ] || {
message "Creating packages list."
make_packages_list
# 注释掉某些冲突的软件包
sed -i -r \
-e 's/^\[mintty-git\].*/#&/g' \
-e 's/^\[getopt\].*/#&/g' \
-e 's/^\[mingw-w64-cross-binutils-git\].*/#&/g' \
-e 's/^\[mingw-w64-cross-gcc-git\].*/#&/g' \
-e 's/^\[dwz\].*/#&/g' \
${GROUPS_LIST_FILE}
}

while [ "${1}" != "" ]; do
build_package ${1}
shift
[ "${1}" == "" ] && exit 0
done

# Build
groups=(
# MSYS2-devel
# msys2-devel
# base-devel
base
libraries
sys-utils
compression
net-utils
perl-modules
python-modules
Database
development
editors
midipix-cross
midipix-cross-toolchain
mingw-w64-cross
mingw-w64-cross-toolchain
VCS
null
)

for group in ${groups[@]}; do
message 'Building packages of group' "${group}"
build_group ${group}
unset group
done

# Deploy
pushd ${PACMAN_LOCAL_REPOSITORY}/${arch}
execute 'SHA-256 checksums' sha256sum *
popd
success 'All artifacts built successfully'
