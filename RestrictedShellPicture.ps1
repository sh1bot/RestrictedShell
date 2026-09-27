# Picture loading helpers for RestrictedShellSetup.ps1.
# For .ico and .exe sources, ask Windows for the representation closest to the
# requested size instead of extracting one small icon and scaling it repeatedly.

if (-not ('RestrictedShell.NativeIcon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RestrictedShell {
    public static class NativeIcon {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern uint PrivateExtractIcons(
            string szFileName,
            int nIconIndex,
            int cxIcon,
            int cyIcon,
            IntPtr[] phicon,
            uint[] piconid,
            uint nIcons,
            uint flags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
'@
}

function Get-PictureBitmap {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Size = 96
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($extension -in '.exe', '.ico') {
        $handles = [IntPtr[]]::new(1)
        $ids = [uint32[]]::new(1)
        $count = [RestrictedShell.NativeIcon]::PrivateExtractIcons(
            $Path, 0, $Size, $Size, $handles, $ids, 1, 0
        )

        if ($count -eq 0 -or $handles[0] -eq [IntPtr]::Zero) {
            throw "Could not extract a $Size x $Size icon from $Path"
        }

        try {
            $icon = [Drawing.Icon]::FromHandle($handles[0])
            try {
                return $icon.ToBitmap()
            }
            finally {
                $icon.Dispose()
            }
        }
        finally {
            [void][RestrictedShell.NativeIcon]::DestroyIcon($handles[0])
        }
    }

    $image = [Drawing.Image]::FromFile($Path)
    try {
        if ($image.Width -eq $Size -and $image.Height -eq $Size) {
            return [Drawing.Bitmap]::new($image)
        }

        $bitmap = [Drawing.Bitmap]::new($Size, $Size)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality

            $scale = [Math]::Min($Size / $image.Width, $Size / $image.Height)
            $width = [Math]::Max(1, [int][Math]::Round($image.Width * $scale))
            $height = [Math]::Max(1, [int][Math]::Round($image.Height * $scale))
            $x = [int](($Size - $width) / 2)
            $y = [int](($Size - $height) / 2)
            $graphics.DrawImage($image, [Drawing.Rectangle]::new($x, $y, $width, $height))
        }
        finally {
            $graphics.Dispose()
        }
        return $bitmap
    }
    finally {
        $image.Dispose()
    }
}

function Install-AccountPicture {
    param($Sid, $Source)

    if (-not $Source -or -not (Test-Path $Source)) {
        return
    }

    $pictureDir = Join-Path $env:ProgramData "RestrictedShell\AccountPictures\$Sid"
    $registryKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$Sid"

    New-Item -ItemType Directory -Path $pictureDir -Force | Out-Null
    New-Item $registryKey -Force | Out-Null

    foreach ($size in 32, 40, 48, 96, 192, 240, 448) {
        # For ICO/EXE, Windows selects the best authored representation for this
        # requested size. Scaling is therefore only a fallback when the source
        # has no suitable representation.
        $bitmap = Get-PictureBitmap -Path $Source -Size $size
        try {
            $filename = Join-Path $pictureDir "Image$size.png"
            $bitmap.Save($filename, [Drawing.Imaging.ImageFormat]::Png)
            New-ItemProperty $registryKey -Name "Image$size" -PropertyType String -Value $filename -Force | Out-Null
        }
        finally {
            $bitmap.Dispose()
        }
    }
}
