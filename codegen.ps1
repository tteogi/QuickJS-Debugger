<#
.SYNOPSIS
    Regenerate gen/ and builtin-*.h files using a clean qjsc build,
    so the output matches upstream quickjs-ng/quickjs.
#>
param(
    [string]$BuildType = "Release"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$QuickJSDir = Join-Path $ScriptDir "quickjs"
Push-Location $QuickJSDir

$BuildDir = "build_codegen"
$QJSC = Join-Path $BuildDir "qjsc.exe"

try {
    # 1. Configure
    Write-Host ">> Configuring ($BuildType) ..." -ForegroundColor Cyan
    $cmakeArgs = @("-B", $BuildDir, "-DCMAKE_BUILD_TYPE=$BuildType")
    # Older MSVC (< 17.5) lacks C11 <stdatomic.h>; use the compat shim from the root project
    $CompatDir = Join-Path $ScriptDir "compat\msvc"
    if (Test-Path $CompatDir) {
        $CompatDir = (Resolve-Path $CompatDir).Path
        Write-Host ">> Adding compat include: $CompatDir" -ForegroundColor Yellow
        $cmakeArgs += "-DCMAKE_C_FLAGS=/I`"$CompatDir`""
    }
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

    # 2. Build qjsc only
    Write-Host ">> Building qjsc ..." -ForegroundColor Cyan
    cmake --build $BuildDir --target qjsc --config $BuildType
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

    if (-not (Test-Path $QJSC)) {
        # MSVC multi-config generators put binaries under Release/Debug subdirs
        $QJSC = Join-Path $BuildDir "$BuildType/qjsc.exe"
        if (-not (Test-Path $QJSC)) {
            throw "qjsc.exe not found in $BuildDir"
        }
    }

    Write-Host ">> Using $QJSC" -ForegroundColor Cyan

    # 3. Normalize JS input files to LF (match upstream Linux builds)
    $jsInputFiles = @(
        'repl.js', 'standalone.js',
        'examples/hello.js', 'examples/hello_module.js',
        'examples/test_fib.js', 'examples/fib_module.js',
        'tests/function_source.js',
        'builtin-array-fromasync.js',
        'builtin-iterator-zip.js',
        'builtin-iterator-zip-keyed.js'
    )
    Write-Host ">> Normalizing JS input files to LF ..." -ForegroundColor Cyan
    foreach ($f in $jsInputFiles) {
        if (Test-Path $f) {
            $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $f))
            $text = [System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllBytes(
                (Resolve-Path $f).Path,
                [System.Text.Encoding]::UTF8.GetBytes($text)
            )
        }
    }

    # 4. Regenerate gen/ files
    & $QJSC -ss -o gen/repl.c -m repl.js
    & $QJSC -ss -o gen/standalone.c -m standalone.js
    & $QJSC -e  -o gen/function_source.c tests/function_source.js
    & $QJSC -e  -o gen/hello.c examples/hello.js
    & $QJSC -e  -o gen/hello_module.c -m examples/hello_module.js
    & $QJSC -e  -o gen/test_fib.c -m examples/test_fib.js

    # 5. Regenerate builtin headers
    & $QJSC -C -ss -o builtin-array-fromasync.h builtin-array-fromasync.js
    & $QJSC -C -ss -o builtin-iterator-zip.h builtin-iterator-zip.js
    & $QJSC -C -ss -o builtin-iterator-zip-keyed.h builtin-iterator-zip-keyed.js

    Write-Host ">> codegen done." -ForegroundColor Green
}
finally {
    # 6. Restore JS files to git's line ending preference and clean up
    Write-Host ">> Restoring JS input files ..." -ForegroundColor Cyan
    Push-Location $QuickJSDir
    git checkout -- repl.js standalone.js examples/ tests/function_source.js builtin-array-fromasync.js builtin-iterator-zip.js builtin-iterator-zip-keyed.js 2>$null
    Pop-Location

    # 7. Remove temporary build directory
    if (Test-Path $BuildDir) {
        Write-Host ">> Removing $BuildDir ..." -ForegroundColor Cyan
        Remove-Item -Recurse -Force $BuildDir
    }
    Pop-Location
}
