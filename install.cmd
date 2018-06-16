@echo off
setlocal

if NOT EXIST "C:\msys%ARCH%-build" (
call :msys_install
) else (
call :msys_init
)

exit /b %ERRORLEVEL%

:msys_install
if EXIST "C:\cygwin\bin" (
call set "PATH=C:\cygwin\bin;%PATH%"
) else if EXIST "C:\msys32\usr\bin" (
call set "PATH=C:\msys32\usr\bin;%PATH%"
) else if EXIST "C:\msys64\usr\bin" (
call set "PATH=C:\msys64\usr\bin;%PATH%"
) else (
echo "No Cygwin or MSYS2 installed on your system."
exit /b 1
)
curl -fsSL -o "%DISTRIB_FILE_NAME%" "%DISTRIB_FILE_URL%"
bash --login -c "pushd C:/; mkdir msys%ARCH%-build; cd msys%ARCH%-build; tar --strip-components=1 -xf $(cygpath \"%CD%\%DISTRIB_FILE_NAME%\"); popd"
C:\msys%ARCH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh INSTALL"
PATH=C:\msys%ARCH%-build\usr\bin;%PATH% && pacman --noconfirm --ask 20 --sync --refresh --refresh --sysupgrade --sysupgrade
PATH=C:\msys%ARCH%-build\usr\bin;%PATH% && pacman --noconfirm --sync --needed base-devel msys2-devel git
C:\msys%ARCH%-build\autorebase.bat
exit /b %ERRORLEVEL%

:msys_init
C:\msys%ARCH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh INSTALL"
exit /b %ERRORLEVEL%
