@echo off
setlocal

if NOT EXIST "C:\msys%WIDTH%-build" (
call :msys_install
) else (
call :msys_init
)

exit /b %ERRORLEVEL%

:msys_install
if %CI_NAME%==drone (
call set "PATH=C:\msys32\usr\bin;%PATH%"
) else if %CI_NAME%==appveyor (
call set "PATH=C:\cygwin\bin;%PATH%"
) else if %CI_NAME%==VSTS (
call set "PATH=C:\Program Files\Git\usr\bin;%PATH%"
) else (
echo "Unsupported CI server %CI_NAME%"
exit /b 1
)

curl -fsSL -o "%DISTRIB_FILE_NAME%" "%DISTRIB_FILE_URL%"
if NOT EXIST %DISTRIB_FILE_NAME% (
echo "Failed to Download MSYS2 distrib package."
exit /b 2
)

bash --login -c "pushd C:/; mkdir msys%WIDTH%-build; cd msys%WIDTH%-build; tar --strip-components=1 -xf $(cygpath \"%CD%\%DISTRIB_FILE_NAME%\"); popd"
C:\msys%WIDTH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh INSTALL"
PATH=C:\msys%WIDTH%-build\usr\bin;%PATH% && pacman --noconfirm --ask 20 --sync --refresh --refresh --sysupgrade --sysupgrade
PATH=C:\msys%WIDTH%-build\usr\bin;%PATH% && pacman --noconfirm --sync --needed base-devel msys2-devel git
call C:\msys%WIDTH%-build\autorebase.bat
exit /b %ERRORLEVEL%

:msys_init
C:\msys%WIDTH%-build\usr\bin\bash --login -c "$(cygpath ${CI_BUILD_DIR})/ci-build.sh INSTALL"
exit /b %ERRORLEVEL%
