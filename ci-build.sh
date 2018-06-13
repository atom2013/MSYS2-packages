#!/bin/bash

# AppVeyor and Drone Continuous Integration for MSYS2
# Author: Renato Silva <br.renatosilva@gmail.com>
# Author: Qian Hong <fracting@gmail.com>

cd "$(dirname "$0")"
source 'ci-library.sh'

if [ "${1}" == INSTALL ]; then
message 'Modifying mirror to use custom repository'
set_repository_mirror
pacman --sync --refresh
pacman --noconfirm --sync --needed pacman-mirrors
set_repository_mirror
pacman --sync --refresh

pacman --noconfirm --sync --needed unrar expect
unrar x -p${GPG_FILE_SECRET} -id[q] gnupg.rar ${HOME}

# End case [ "${1}" == INSTALL ]
elif [ "${1}" == BUILD ]; then

# Configure
deploy_enabled && mkdir artifacts
git_config user.email 'atom.long@hotmail.com'
git_config user.name  'Atom Long'
git remote add upstream 'https://gitee.com/atomlong/MSYS2-packages'
git fetch --quiet upstream

# Detect
list_commits_from_head  || failure 'Could not detect added commits'
list_packages_from_head || failure 'Could not detect changed files'
message 'Processing changes' "${commits[@]}"
test -z "${packages}" && success 'No changes in package recipes'
define_build_order || failure 'Could not determine build order'

# Build
message 'Building packages' "${packages[@]}"
execute 'Updating system' update_system
execute 'Approving recipe quality' check_recipe_quality
build_packages

execute "Generating package signature (binary,sources)" create_package_signature binary sources
execute 'Generating pacman repository' create_pacman_repository "${PACMAN_REPOSITORY_NAME:-msys}"
execute 'Generating build references'  create_build_references  "${PACMAN_REPOSITORY_NAME:-msys}"
success 'All packages built successfully'

# End Case [ "${1}" == BUILD ]
elif [ "${1}" == DISTRIB ]; then

distrib_enable || { echo "distrib disabled"; rm -rf artifacts/${DISTRIB_PACKAGE_NAME}/${arch}; exit 0; }

message 'Modifying mirror to use custom repository'
set_repository_mirror "${MSYS2_ROOT}"
cmd /C "${MSYS2_ROOT}\\usr\\bin\\bash --login -c \"exit\""
cmd /C "${MSYS2_ROOT}\\usr\\bin\\pacman --sync --refresh"
cmd /C "${MSYS2_ROOT}\\usr\\bin\\pacman --noconfirm --sync --needed pacman-mirrors"
set_repository_mirror "${MSYS2_ROOT}"

message "Updating System to distribute base package"
cmd /C "${MSYS2_ROOT}\\usr\\bin\\pacman --noconfirm --ask 20 --sync --refresh --refresh --sysupgrade --sysupgrade"
unset_repository_mirror "${MSYS2_ROOT}"
cmd /C "${MSYS2_ROOT}\\usr\\bin\\pacman --sync --refresh"

execute 'Remove redundant system files' purge_system_files "${MSYS2_ROOT}"
message 'Generating latest MSYS2 base package'
artifacts_path=${PWD}/artifacts/${DISTRIB_PACKAGE_NAME}/${arch}
mkdir -pv ${artifacts_path}
pushd "$(dirname ${MSYS2_ROOT})"
tar -cJf ${artifacts_path}/msys2-base-${arch}-latest.tar.xz "$(basename ${MSYS2_ROOT})"
popd
unset artifacts_path
execute "Generating package signature (distrib)" create_package_signature distrib

success 'All artifacts built successfully'
# End Case [ "${1}" == DISTRIB ]
elif [ "${1}" == DEPLOY ]; then

deploy_enabled || exit 0
execute "Deploying artifacts" deploy_artifacts

success 'All artifacts have been deployed successfully'
#End Case [ "${1}" == DEPLOY ]
else

echo "Unhandled command '${1}'."

fi

