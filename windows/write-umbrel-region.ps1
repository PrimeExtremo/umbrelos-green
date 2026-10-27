$ErrorActionPreference = 'Stop'
# Writes the UmbrelOS image into a fixed region of the SD card, 1 GiB in, after the
# installer. Does NOT clear the card: the installer must already be on it.
$ExpectedUniqueId = 'USBSTOR\DISK&VEN_GENERIC&PROD_MASSSTORAGECLASS&REV_1539\000000001539&1:PrimePC'
$ExpectedSize = 63281561600L
$ImagePath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\outputs\umbrelos-2.0.0-green-emmc.img'
$ImageHash = '447ec4c8576773e7ca6b17b8c03dcd281ab43de0e5b4efc2bf318566f683eb04'
$InstallerPath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\outputs\green-umbrel-installer.img'
$InstallerHash = '5020bc449b889f9f9041ca14d5a355159db5ff18bf65e790504d10f174010f54'
$OffsetBytes = 1073741824L
$ResultPath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\work\umbrel-region-result.json'
$LogPath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\work\umbrel-region.log'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RawRegionIO {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetFilePointerEx(SafeFileHandle handle, long distance, IntPtr newPointer, uint method);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteFile(SafeFileHandle handle, byte[] buffer, int count, out int written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadFile(SafeFileHandle handle, byte[] buffer, int count, out int read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FlushFileBuffers(SafeFileHandle handle);
}
'@

Start-Transcript -Path $LogPath -Force
try {
    $image = Get-Item -LiteralPath $ImagePath
    if ((Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ImageHash) { throw 'UmbrelOS image checksum mismatch' }
    if ((Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $InstallerHash) { throw 'Installer image checksum mismatch' }

    $disk = @(Get-Disk | Where-Object UniqueId -eq $ExpectedUniqueId)
    if ($disk.Count -ne 1) { throw "Expected one matching card, found $($disk.Count)" }
    $disk = $disk[0]
    if ($disk.Number -ne 5 -or $disk.BusType -ne 'USB' -or $disk.Size -ne $ExpectedSize -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly) { throw 'SD safety preflight failed' }
    if ($OffsetBytes + $image.Length -gt $disk.Size) { throw 'Region does not fit on card' }

    # The installer must still be on the card. Read its first bytes back to confirm.
    $device = "\\.\PhysicalDrive$($disk.Number)"
    $probe = [RawRegionIO]::CreateFile($device, 2147483648, 3, [IntPtr]::Zero, 3, 134217728, [IntPtr]::Zero)
    if ($probe.IsInvalid) { throw "Probe CreateFile failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    $probeBuf = [byte[]]::new(4096)
    $pr = 0
    # Probe the bootloader at 32 KiB: Windows rewrites the GPT header in the first sectors.
    [void][RawRegionIO]::SetFilePointerEx($probe, 32768, [IntPtr]::Zero, 0)
    [void][RawRegionIO]::ReadFile($probe, $probeBuf, 4096, [ref]$pr, [IntPtr]::Zero)
    $probe.Dispose()
    if ($pr -ne 4096) { throw "Probe read returned $pr bytes" }
    $expectedFirst = [IO.File]::ReadAllBytes($InstallerPath)[32768..36863]
    if ([BitConverter]::ToString($probeBuf) -ne [BitConverter]::ToString($expectedFirst)) { throw 'Installer not present at start of card; refusing to write' }

    $handle = [RawRegionIO]::CreateFile($device, 3221225472, 3, [IntPtr]::Zero, 3, 2147483648, [IntPtr]::Zero)
    if ($handle.IsInvalid) { throw "CreateFile failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    $source = [IO.File]::OpenRead($ImagePath)
    try {
        if (-not [RawRegionIO]::SetFilePointerEx($handle, $OffsetBytes, [IntPtr]::Zero, 0)) { throw "Seek failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        $buffer = [byte[]]::new(4194304)
        $total = 0L
        $next = 536870912L
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $written = 0
            if (-not [RawRegionIO]::WriteFile($handle, $buffer, $count, [ref]$written, [IntPtr]::Zero)) {
                throw "WriteFile failed at byte $total`: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            if ($written -ne $count) { throw "Short write at byte $total`: $written of $count" }
            $total += $written
            if ($total -ge $next) { Write-Host ("Written {0:N1} GiB" -f ($total / 1GB)); $next += 536870912L }
        }
        if ($total -ne $image.Length) { throw "Write length mismatch: $total" }
        if (-not [RawRegionIO]::FlushFileBuffers($handle)) { throw "Flush failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    }
    finally {
        $source.Dispose()
        $handle.Dispose()
    }

    # Read the region back and hash it.
    $handle = [RawRegionIO]::CreateFile($device, 2147483648, 3, [IntPtr]::Zero, 3, 134217728, [IntPtr]::Zero)
    if ($handle.IsInvalid) { throw "Readback CreateFile failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        if (-not [RawRegionIO]::SetFilePointerEx($handle, $OffsetBytes, [IntPtr]::Zero, 0)) { throw "Readback seek failed" }
        $buffer = [byte[]]::new(4194304)
        $remaining = $image.Length
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min([long]$buffer.Length, [long]$remaining)
            $read = 0
            if (-not [RawRegionIO]::ReadFile($handle, $buffer, $wanted, [ref]$read, [IntPtr]::Zero)) { throw "Readback failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
            if ($read -le 0) { throw "Short readback with $remaining bytes remaining" }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $remaining -= $read
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        $readbackHash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $handle.Dispose()
    }
    if ($readbackHash -ne $ImageHash) { throw "Readback checksum mismatch: $readbackHash" }
    Update-HostStorageCache
    [pscustomobject]@{success=$true; disk_number=$disk.Number; offset_bytes=$OffsetBytes; image_size=$image.Length; sha256=$readbackHash; completed_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
    Write-Host 'UmbrelOS region written and readback verified'
}
catch {
    [pscustomobject]@{success=$false; error=$_.Exception.Message; completed_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
    throw
}
finally { Stop-Transcript }
