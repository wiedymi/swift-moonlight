function Open-SwiftMoonlightInputTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url
    )

    Add-Type -AssemblyName System.Windows.Forms

    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::AllScreens |
        Sort-Object {
            $bounds = $_.Bounds
            $centerX = $bounds.X + ($bounds.Width / 2)
            $centerY = $bounds.Y + ($bounds.Height / 2)
            [Math]::Abs($centerX - $cursor.X) + [Math]::Abs($centerY - $cursor.Y)
        } |
        Select-Object -First 1

    if ($null -eq $screen) {
        Start-Process $Url
        return
    }

    $bounds = $screen.Bounds
    $edgeCandidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "msedge.exe"
    )
    $edge = $edgeCandidates | Where-Object { $_ -eq "msedge.exe" -or (Test-Path $_) } | Select-Object -First 1
    $arguments = @(
        "--new-window",
        "--start-fullscreen",
        "--window-position=$($bounds.X),$($bounds.Y)",
        "--window-size=$($bounds.Width),$($bounds.Height)",
        $Url
    )

    try {
        Start-Process -FilePath $edge -ArgumentList $arguments
    } catch {
        Start-Process $Url
    }
}

function o {
    param(
        [Parameter(Mandatory = $true)]
        [string] $u
    )

    Open-SwiftMoonlightInputTarget -Url $u
}
