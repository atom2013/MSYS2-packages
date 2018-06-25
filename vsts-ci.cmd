@echo off

REM read variables from arguments
call %~1
call %~2
call %~3

REM Set CI system Variables
set CI=%TF_BUILD%
set CI_NAME=VSTS
set CI_REPO=%BUILD_REPOSITORY_NAME%
set CI_BRANCH=%BUILD_SOURCEBRANCHNAME%
set CI_COMMIT=%BUILD_SOURCEVERSION%
set CI_BUILD_NUMBER=%BUILD_BUILDID%
set CI_BUILD_DIR=%SYSTEM_DEFAULTWORKINGDIRECTORY%
set CI_BUILD_URL="https://atomlong.visualstudio.com/%SYSTEM_TEAMPROJECT%/_build/index?buildId=%BUILD_BUILDID%&_a=summary"

REM Target application architecture information
set ARCH=i686
set WIDTH=32

REM Information on demployment.
set DEPLOY_PROVIDER=bintray
set BINTRAY_ACCOUNT=atomlong
set BINTRAY_REPOSITORY=msys2
set BINTRAY_VERSION=latest
set PACMAN_REPOSITORY_NAME=msys
set DISTRIB_PACKAGE_NAME=distrib

REM Secret Variables
if not defined BINTRAY_API_KEY (
echo "Please set Secret Variable BINTRAY_API_KEY."
exit /b 1
)

if not defined GPG_KEY_PASSWD (
echo "Please set Secret Variable GPG_KEY_PASSWD."
exit /b 1
)

if not defined GPG_FILE_SECRET (
echo "Please set Secret Variable GPG_FILE_SECRET."
exit /b 1
)

REM Information on MSYS2 distrib package.
set MSYS2_ROOT=C:\msys%WIDTH%
set DISTRIB_FILE_URL=https://dl.bintray.com/%BINTRAY_ACCOUNT%/%BINTRAY_REPOSITORY%/%DISTRIB_PACKAGE_NAME%/%ARCH%/msys2-base-%ARCH%-latest.tar.xz
set DISTRIB_FILE_NAME=msys2-base-%ARCH%-latest.tar.xz

REM Install MSYS2 on the agent machine.
if EXIST %BUILD_BINARIESDIRECTORY%\msys%WIDTH%-build.tar.xz (
call :install_msys
)
call install.cmd
REM Run build script
C:\msys%WIDTH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh BUILD"
REM Run distrib script
C:\msys%WIDTH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh DISTRIB"
REM Run deploy script
C:\msys%WIDTH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh DEPLOY"
REM Run cache script
C:\msys%WIDTH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh CACHE"
rm -f "%BUILD_BINARIESDIRECTORY%\msys%WIDTH%-build.tar.xz"
pushd C:\
bash --login -c "tar -cJf $(cygpath \"%BUILD_BINARIESDIRECTORY%\\msys%WIDTH%-build.tar.xz\") msys%WIDTH%-build"
popd

exit /b %ERRORLEVEL%

:install_msys
bash --login -c "tar -xf $(cygpath \"%BUILD_BINARIESDIRECTORY%\msys%WIDTH%-build.tar.xz\") -C /c/"
exit /b %ERRORLEVEL%
